defmodule PhoenixKitBilling.ProviderRefunds do
  @moduledoc """
  Refunds that move money: the refund is made at the payment provider that took
  the payment, then recorded in the ledger. Reached through
  `PhoenixKitBilling.refund_at_provider/3`.

  `PhoenixKitBilling.record_refund/3` only books a refund - it is for money
  returned some other way (a bank transfer). Before this module nothing in billing
  ever called `Providers.create_refund/4`: an operator who chose "Stripe" in the
  refund dialog booked a refund in the ledger, voided the invoice when it reached
  zero, and the customer never got the money back.

  ## Which payments are refunded

  The invoice's provider payments: positive ledger rows whose `payment_method` is a
  registered provider (`"stripe"`, `"paypal"`, ...) and that carry the provider's
  id for the payment. Newest first; `:provider` and `:transaction_uuid` narrow the
  choice. Each payment can give back what it took less the refunds already
  recorded against it - a refund names the payment it reversed in its
  `provider_data` (`"charge_id"`, `"payment_intent_id"`). One that names no
  payment (recorded by hand) is counted once, through the cap of the whole by the
  invoice's `paid_amount`, not against each payment; one the provider failed and
  billing put back (`reversed_by_uuid`) counts nowhere. (The refund webhooks
  reconcile a charge's running total more cautiously: there a refund recorded by
  hand counts against the charge, so that nothing is booked twice.)

  Without `:amount` everything refundable is refunded (one provider refund per
  payment). An amount is taken from the newest payments first, split across them
  when one does not cover it.

  ## Idempotency

  - Every provider call carries an idempotency key (Stripe's `Idempotency-Key`):
    `:idempotency_key` with the payment's uuid appended, or by default one made of
    the payment, the refunds already recorded against it and the amount. A retry
    made before the first is in the ledger - two concurrent clicks, a crash
    between the provider's answer and the ledger - gets the refund already made
    back, not a second one. A repeat AFTER the first was recorded is a new refund
    under the default key (what is recorded has changed); a caller that means
    "the same refund" passes its own `:idempotency_key`, as the admin dialog does
    (one per opening). Stripe keeps a key for 24 hours.
  - The ledger row is the refund's own id (`provider_transaction_id`), written under
    the invoice lock. A refund id already in the ledger is not booked again, and
    neither is a part the provider's refund webhook booked first (the webhook
    reconciles the charge's running total, so whichever lands second adds nothing).

  ## Results

  `{:ok, [result]}`, one per payment refunded, each
  `%{payment: Transaction.t(), refund: RefundResult.t(), transaction: Transaction.t() | nil}`
  (`transaction` is nil when the refund was already in the ledger), or:

  - `{:error, :invoice_trashed}` / `{:error, :invoice_not_found}`
  - `{:error, :currency_too_precise}` - the invoice's currency has more than two
    decimal places (BHD, KWD, ...), which the ledger's amounts cannot hold
  - `{:error, :no_provider_payments}` - nothing on the invoice was paid through a provider
  - `{:error, :already_refunded}` - the provider payments are refunded already
  - `{:error, :invalid_amount}` / `{:error, :exceeds_paid_amount}` /
    `{:error, :exceeds_refundable}` - an amount that does not fit
  - `{:error, reason}` - the provider refused the first refund; nothing changed
  - `{:error, {:refunded_not_recorded, refund, reason}}` - the provider made the
    refund and the ledger insert failed: the refund webhook books it, or record it
    by hand with the refund's id
  - `{:error, {:partially_refunded, results, reason}}` - an earlier payment was
    refunded (and is in `results`), a later one failed
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Providers, Transaction}
  alias PhoenixKitBilling.Providers.MinorUnits
  alias PhoenixKitBilling.Providers.Types.RefundResult

  @doc "See the moduledoc and `PhoenixKitBilling.refund_at_provider/3`."
  def refund(%Invoice{trashed_at: %DateTime{}}, _attrs, _admin_user),
    do: {:error, :invoice_trashed}

  def refund(%Invoice{uuid: uuid}, attrs, admin_user) do
    attrs = normalize_attrs(attrs)

    with {:ok, invoice} <- fetch_refundable_invoice(uuid),
         :ok <- Billing.check_ledger_currency(invoice.currency),
         {:ok, payments} <- refundable_payments(invoice, attrs),
         {:ok, plan} <- plan(invoice, payments, attrs.amount) do
      execute(invoice, plan, attrs, admin_user)
    end
  end

  defp fetch_refundable_invoice(uuid) do
    case repo().get(Invoice, uuid) do
      nil -> {:error, :invoice_not_found}
      %Invoice{trashed_at: %DateTime{}} -> {:error, :invoice_trashed}
      invoice -> {:ok, invoice}
    end
  end

  @doc """
  What `refund/3` could give back through `provider` (or any provider when nil) on
  `invoice` right now: the sum over its provider payments, capped by `paid_amount`.
  """
  @spec refundable_amount(Invoice.t(), atom() | String.t() | nil) :: Decimal.t()
  def refundable_amount(%Invoice{} = invoice, provider \\ nil) do
    case refundable_payments(invoice, %{provider: provider && to_string(provider)}) do
      {:ok, payments} ->
        payments
        |> Enum.reduce(Decimal.new(0), fn {_payment, refundable}, sum ->
          Decimal.add(sum, refundable)
        end)
        |> Decimal.min(invoice.paid_amount || Decimal.new(0))

      {:error, _} ->
        Decimal.new(0)
    end
  end

  # ===========================================================================
  # Choosing the payments
  # ===========================================================================

  defp normalize_attrs(attrs) do
    get = fn key -> Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) end

    %{
      amount: parse_amount(get.(:amount)),
      description: blank_to_nil(get.(:description)),
      reason: blank_to_nil(get.(:reason)),
      provider: get.(:provider) && to_string(get.(:provider)),
      transaction_uuid: get.(:transaction_uuid),
      idempotency_key: blank_to_nil(get.(:idempotency_key))
    }
  end

  defp parse_amount(nil), do: nil
  defp parse_amount(""), do: nil
  defp parse_amount(%Decimal{} = amount), do: amount
  defp parse_amount(amount) when is_integer(amount), do: Decimal.new(amount)

  defp parse_amount(amount) when is_binary(amount) do
    case Decimal.parse(String.trim(amount)) do
      {decimal, ""} -> decimal
      _ -> :invalid
    end
  end

  defp parse_amount(_amount), do: :invalid

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  # `{:ok, [{payment, refundable}]}`, newest payment first, only those with
  # something left to give back.
  defp refundable_payments(%Invoice{uuid: uuid}, attrs) do
    payments = provider_payments(uuid, attrs)
    refunds = refund_rows(uuid)

    refundable =
      payments
      |> Enum.map(fn payment -> {payment, refundable_on(payment, refunds)} end)
      |> Enum.filter(fn {_payment, amount} -> Decimal.positive?(amount) end)

    cond do
      payments == [] -> {:error, :no_provider_payments}
      refundable == [] -> {:error, :already_refunded}
      true -> {:ok, refundable}
    end
  end

  defp provider_payments(invoice_uuid, attrs) do
    providers = Enum.map(Providers.all_providers(), &Atom.to_string/1)

    providers =
      case Map.get(attrs, :provider) do
        nil -> providers
        provider -> Enum.filter(providers, &(&1 == provider))
      end

    query =
      from(t in Transaction,
        where:
          t.invoice_uuid == ^invoice_uuid and t.amount > 0 and
            t.payment_method in ^providers and not is_nil(t.provider_transaction_id),
        order_by: [desc: t.inserted_at, desc: t.uuid]
      )

    query =
      case Map.get(attrs, :transaction_uuid) do
        nil -> query
        tx_uuid -> where(query, [t], t.uuid == ^tx_uuid)
      end

    repo().all(query)
  end

  defp refund_rows(invoice_uuid) do
    repo().all(
      from(t in Transaction,
        where: t.invoice_uuid == ^invoice_uuid and t.amount < 0,
        select: %{
          amount: t.amount,
          payment_method: t.payment_method,
          provider_data: t.provider_data
        }
      )
    )
  end

  defp refundable_on(payment, refunds) do
    payment.amount
    |> Decimal.sub(recorded_against(payment, refunds))
    |> Decimal.max(Decimal.new(0))
  end

  @doc false
  # The refunds recorded against `payment`: those of its method that name it. A
  # refund recorded by hand names no payment; it is not counted against each one
  # (that made an invoice with two payments refundable twice over less), but once,
  # through the `paid_amount` cap. A refund the provider failed, put back on the
  # invoice (`reversed_by_uuid`), gave nothing back.
  def recorded_against(payment, refunds) do
    ids = payment_ids(payment)

    refunds
    |> Enum.filter(fn refund ->
      data = refund.provider_data || %{}

      refund.payment_method == payment.payment_method and not reversed?(data) and
        names_payment?(data, ids, payment.uuid)
    end)
    |> Enum.reduce(Decimal.new(0), fn refund, sum ->
      Decimal.add(sum, Decimal.abs(refund.amount))
    end)
  end

  defp reversed?(provider_data), do: is_binary(provider_data["reversed_by_uuid"])

  defp names_payment?(provider_data, ids, payment_uuid) do
    case provider_data["refunded_transaction_uuid"] do
      uuid when is_binary(uuid) ->
        uuid == payment_uuid

      _ ->
        [provider_data["charge_id"], provider_data["payment_intent_id"]]
        |> Enum.reject(&is_nil/1)
        |> Enum.any?(&(&1 in ids))
    end
  end

  # Every id a payment is known by: the one it was recorded under and the charge
  # and payment-intent ids its provider data carries.
  defp payment_ids(%Transaction{} = payment) do
    data = payment.provider_data || %{}

    [payment.provider_transaction_id, data["charge_id"], data["payment_intent_id"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  # ===========================================================================
  # Planning the amounts
  # ===========================================================================

  defp plan(_invoice, _payments, :invalid), do: {:error, :invalid_amount}

  defp plan(invoice, payments, nil) do
    {:ok, allocate(payments, invoice.paid_amount)}
  end

  defp plan(invoice, payments, %Decimal{} = amount) do
    available =
      Enum.reduce(payments, Decimal.new(0), fn {_payment, refundable}, sum ->
        Decimal.add(sum, refundable)
      end)

    cond do
      not Decimal.positive?(amount) -> {:error, :invalid_amount}
      finer_than_currency?(amount, invoice.currency) -> {:error, :invalid_amount}
      Decimal.compare(amount, invoice.paid_amount) == :gt -> {:error, :exceeds_paid_amount}
      Decimal.compare(amount, available) == :gt -> {:error, :exceeds_refundable}
      true -> {:ok, allocate(payments, amount)}
    end
  end

  # An amount the currency cannot carry (5.005 EUR, 10.5 JPY) is refused before any
  # provider call: split across payments, the newest could be refunded in full and
  # the fractional rest refused by the provider, leaving a part refund behind.
  defp finer_than_currency?(amount, currency) do
    MinorUnits.to_minor_units(amount, currency) == {:error, :fractional_amount}
  end

  # Newest payment first, each giving what it can until `total` is reached.
  defp allocate(payments, total) do
    {plan, _left} =
      Enum.reduce(payments, {[], total}, fn {payment, refundable}, {plan, left} ->
        if Decimal.positive?(left) do
          take = Decimal.min(refundable, left)
          {[{payment, take} | plan], Decimal.sub(left, take)}
        else
          {plan, left}
        end
      end)

    Enum.reverse(plan)
  end

  # ===========================================================================
  # Refunding and recording
  # ===========================================================================

  defp execute(invoice, plan, attrs, admin_user) do
    plan
    |> Enum.reduce_while({:ok, []}, fn {payment, amount}, {:ok, done} ->
      case refund_payment(invoice, payment, amount, attrs, admin_user) do
        {:ok, result} ->
          {:cont, {:ok, [result | done]}}

        {:error, reason} when done == [] ->
          {:halt, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, {:partially_refunded, Enum.reverse(done), reason}}}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end

  defp refund_payment(invoice, payment, amount, attrs, admin_user) do
    before = recorded_against(payment, refund_rows(invoice.uuid))

    opts =
      [
        currency: invoice.currency,
        idempotency_key: idempotency_key(attrs, payment, before, amount),
        metadata: %{
          "invoice_uuid" => invoice.uuid,
          "invoice_number" => invoice.invoice_number,
          "transaction_uuid" => payment.uuid
        }
      ]
      |> put_opt(:reason, attrs.reason)
      |> put_opt(:note, attrs.description)

    case Providers.create_refund(
           payment.payment_method,
           payment.provider_transaction_id,
           amount,
           opts
         ) do
      {:ok, %RefundResult{} = refund} ->
        record(invoice, payment, refund, amount, before, attrs, admin_user)

      {:error, reason} ->
        Logger.warning(
          "[Billing] #{payment.payment_method} refused the refund of #{amount} " <>
            "#{invoice.currency} on invoice #{invoice.invoice_number}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp idempotency_key(%{idempotency_key: key}, payment, _before, _amount) when is_binary(key),
    do: "#{key}:#{payment.uuid}"

  defp idempotency_key(_attrs, payment, before, amount),
    do: "pkb-refund:#{payment.uuid}:#{Decimal.to_string(before)}:#{Decimal.to_string(amount)}"

  defp record(invoice, payment, refund, amount, before, attrs, admin_user) do
    refunded = refunded_amount(refund, amount)
    refund_id = refund.provider_refund_id || refund.id
    payment_data = payment.provider_data || %{}

    ledger_attrs = %{
      payment_method: payment.payment_method,
      description: attrs.description || "Refund via #{payment.payment_method}",
      provider_transaction_id: refund_id,
      provider_data: %{
        "refund_id" => refund_id,
        "refund_status" => refund.status,
        "refunded_transaction_uuid" => payment.uuid,
        "charge_id" =>
          refund.metadata["charge_id"] || payment_data["charge_id"] ||
            charge_id_of(payment.provider_transaction_id),
        "payment_intent_id" =>
          refund.metadata["payment_intent_id"] || payment_data["payment_intent_id"] ||
            intent_id_of(payment.provider_transaction_id),
        "source" => "refund_at_provider"
      }
    }

    result =
      Billing.record_provider_refund(
        invoice,
        ledger_attrs,
        fn locked -> unbooked_part(locked, payment, refund_id, before, refunded) end,
        admin_user
      )

    case result do
      {:ok, transaction} ->
        {:ok, %{payment: payment, refund: refund, transaction: transaction}}

      {:error, :already_recorded} ->
        {:ok, %{payment: payment, refund: refund, transaction: nil}}

      {:error, reason} ->
        Logger.error(
          "[Billing] #{payment.payment_method} refund #{refund_id} of #{refunded} " <>
            "#{invoice.currency} on invoice #{invoice.invoice_number} was made but NOT " <>
            "recorded: #{inspect(reason)}. The provider's refund webhook books it; " <>
            "otherwise record it by hand with this refund id."
        )

        {:error, {:refunded_not_recorded, refund, reason}}
    end
  end

  # Under the invoice lock: nothing when this refund id is booked already, else
  # what the ledger lacks of it - a webhook may have booked it (without the id)
  # since `before` was read.
  defp unbooked_part(locked, payment, refund_id, before, refunded) do
    refunds = refund_rows(locked.uuid)

    if refund_id_booked?(locked.uuid, refund_id) do
      {:error, :already_recorded}
    else
      missing =
        before
        |> Decimal.add(refunded)
        |> Decimal.sub(recorded_against(payment, refunds))
        |> Decimal.min(refunded)

      if Decimal.positive?(missing), do: {:ok, missing}, else: {:error, :already_recorded}
    end
  end

  defp refund_id_booked?(_invoice_uuid, nil), do: false

  defp refund_id_booked?(invoice_uuid, refund_id) do
    repo().exists?(
      from(t in Transaction,
        where:
          t.invoice_uuid == ^invoice_uuid and t.amount < 0 and
            t.provider_transaction_id == ^refund_id
      )
    )
  end

  defp refunded_amount(%RefundResult{amount: %Decimal{} = amount}, _requested), do: amount
  defp refunded_amount(_refund, requested), do: requested

  defp charge_id_of("pi_" <> _), do: nil
  defp charge_id_of(id), do: id

  defp intent_id_of("pi_" <> _ = id), do: id
  defp intent_id_of(_id), do: nil

  defp repo, do: RepoHelper.repo()
end
