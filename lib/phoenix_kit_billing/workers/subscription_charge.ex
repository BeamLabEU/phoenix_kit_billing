defmodule PhoenixKitBilling.Workers.SubscriptionCharge do
  @moduledoc """
  Charging a subscription for its period: what the renewal and dunning workers share.

  A period has one invoice, found by the subscription and the period's end (stored
  under `metadata["period_end"]`), and that invoice is what gets charged. So a retry
  finds the invoice a decline left open, and a period paid some other way (*Mark
  paid*, or the webhook of a charge whose worker crashed) is not charged again.

  It takes two transactions:

    1. Under the subscription's row lock, find or create the invoice, and commit. The
       invoice counter is released here, so no other invoice waits on a provider.
    2. Under the subscription's and the invoice's row locks, charge, record and move
       the subscription to its next period.

  What the locks hold off: a second worker, which finds the period moved on, and a
  void or a payment of the invoice, which wait for the charge to be recorded.

  ## A crash past the charge

  The second transaction rolls back and the invoice survives, so the retry charges
  that invoice again. Two things keep that from reaching the card twice:

    * the provider is told the invoice (`:invoice_uuid`), so the webhook of the first
      charge pays it, and the retry finds it paid. PayPal's events do not carry it;
    * the charge carries an `:idempotency_key` made from the invoice and the attempt:
      a retry of the same attempt repeats the key, and a decline, which commits a new
      attempt, moves it on, or the provider would replay the decline.

  Only Stripe honours the key: PayPal charges in two calls that one key cannot cover,
  and Razorpay and EveryPay have none. So with those, a retry that gets there before
  the webhook can still charge twice, as it always could.
  """

  import Ecto.Query

  alias PhoenixKit.RepoHelper
  alias PhoenixKitBilling, as: Billing

  alias PhoenixKitBilling.{
    Invoice,
    Notifications,
    PaymentMethod,
    Providers,
    Subscription,
    SubscriptionType
  }

  require Logger

  @typedoc """
  `:description` is sent to the provider and put on the ledger row. `:due?` is asked
  on the locked subscription, before each transaction: `false` leaves everything
  alone. `:declined` runs under the lock when the invoice could not be made or the
  card was refused, and its return value is returned.
  """
  @type opts :: [
          description: String.t(),
          due?: (Subscription.t() -> boolean()),
          declined: (Subscription.t(), term() -> term())
        ]

  @doc """
  Charges the subscription for its current period.

  Returns `{:ok, subscription}` for a paid period, `{:ok, :skipped}` when it is not
  due, what `:declined` returns, or `{:error, {:charged_not_recorded, reason}}` when
  the money was taken and the ledger refused it. **That last one must not be retried:**
  an operator has to reconcile it, and has been told to.
  """
  @spec run(Subscription.t(), opts()) :: term()
  def run(%Subscription{} = subscription, opts) do
    due? = Keyword.fetch!(opts, :due?)
    declined = Keyword.fetch!(opts, :declined)

    result =
      under_lock(subscription, fn locked ->
        if due?.(locked), do: period_invoice(locked), else: :skipped
      end)

    case result do
      {:ok, %Invoice{} = invoice} -> settle(subscription, invoice, opts)
      {:error, reason} -> under_lock(subscription, &declined.(&1, reason))
      :skipped -> {:ok, :skipped}
    end
  end

  @doc """
  Ends the subscription now and voids what it still has open: nothing is owed for a
  period that was not given. An invoice with money on it is left for an operator
  (`:invoice_has_payments`).
  """
  @spec end_subscription(Subscription.t(), String.t()) ::
          {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def end_subscription(%Subscription{} = subscription, reason) do
    with {:ok, cancelled} <- Billing.cancel_subscription(subscription, immediately: true) do
      void_open_invoices(cancelled, reason)
      {:ok, cancelled}
    end
  end

  defp void_open_invoices(%Subscription{uuid: uuid}, reason) do
    from(i in Invoice,
      where:
        i.subscription_uuid == ^uuid and i.status in ["sent", "overdue"] and
          is_nil(i.trashed_at)
    )
    |> RepoHelper.repo().all()
    |> Enum.each(fn invoice ->
      with {:error, refusal} <- Billing.void_invoice(invoice, reason) do
        Logger.warning(
          "Invoice #{invoice.invoice_number} left open on ended subscription #{uuid}: " <>
            inspect(refusal)
        )
      end
    end)
  end

  defp under_lock(%Subscription{} = subscription, fun) do
    repo = RepoHelper.repo()

    {:ok, result} =
      repo.transaction(fn ->
        case lock_subscription(subscription, repo) do
          nil -> :skipped
          locked -> fun.(locked)
        end
      end)

    result
  end

  defp lock_subscription(%Subscription{uuid: uuid}, repo) do
    from(s in Subscription,
      where: s.uuid == ^uuid,
      lock: "FOR UPDATE",
      preload: [:subscription_type, :payment_method]
    )
    |> repo.one()
  end

  defp period_invoice(%Subscription{} = subscription) do
    case find_period_invoice(subscription) do
      nil -> create_period_invoice(subscription)
      invoice -> {:ok, invoice}
    end
  end

  # A void or trashed invoice is no longer the period's: dunning goes on, and makes
  # another.
  defp find_period_invoice(%Subscription{uuid: uuid} = subscription) do
    period_end = period_key(subscription)

    from(i in Invoice,
      where: i.subscription_uuid == ^uuid and i.status != "void" and is_nil(i.trashed_at),
      where: fragment("?->>'period_end' = ?", i.metadata, ^period_end),
      order_by: [desc: i.inserted_at, desc: i.uuid],
      limit: 1
    )
    |> RepoHelper.repo().one()
  end

  defp period_key(%Subscription{current_period_end: period_end}) do
    DateTime.to_iso8601(period_end)
  end

  defp create_period_invoice(%Subscription{subscription_type: nil}), do: {:error, :no_plan}

  defp create_period_invoice(%Subscription{subscription_type: plan} = subscription) do
    line_items = [
      %{
        "name" => "#{plan.name} subscription",
        "description" => "#{SubscriptionType.interval_description(plan)}",
        "quantity" => 1,
        "unit_price" => plan.price,
        "total" => plan.price
      }
    ]

    Billing.create_invoice(subscription.user_uuid, %{
      subscription_uuid: subscription.uuid,
      billing_profile_uuid: subscription.billing_profile_uuid,
      currency: plan.currency,
      status: "sent",
      due_date: Date.utc_today(),
      notes: "Subscription renewal: #{plan.name}",
      line_items: line_items,
      subtotal: plan.price,
      total: plan.price,
      metadata: %{"period_end" => period_key(subscription)}
    })
  end

  defp settle(%Subscription{} = subscription, %Invoice{} = invoice, opts) do
    repo = RepoHelper.repo()

    result =
      repo.transaction(fn ->
        with %Subscription{} = locked <- lock_subscription(subscription, repo),
             true <- opts[:due?].(locked),
             %Invoice{} = locked_invoice <- lock_invoice(invoice, repo) do
          pay(locked, locked_invoice, opts, repo)
        else
          _gone_or_no_longer_due -> :skipped
        end
      end)

    # After the commit: a notification reports a committed fact, and in a transaction
    # the ledger aborted its write would be lost.
    case result do
      {:ok, {:paid, renewed, amount}} ->
        _ = Notifications.payment_received(invoice, amount)
        {:ok, renewed}

      {:ok, :skipped} ->
        {:ok, :skipped}

      {:ok, other} ->
        other

      {:error, {:charged_not_recorded, reason}} = error ->
        _ = Notifications.payment_failed(invoice, reason)
        error
    end
  end

  defp lock_invoice(%Invoice{uuid: uuid}, repo) do
    from(i in Invoice, where: i.uuid == ^uuid, lock: "FOR UPDATE")
    |> repo.one()
  end

  # Before any charge: moving to the next period needs the plan, and that comes after.
  defp pay(%Subscription{subscription_type: nil} = locked, _invoice, opts, _repo) do
    opts[:declined].(locked, :no_plan)
  end

  # Paid since the invoice was found, or before: the money is in, nothing is charged.
  defp pay(%Subscription{} = locked, %Invoice{status: "paid"}, _opts, repo) do
    next_period(locked, repo)
  end

  defp pay(%Subscription{} = locked, %Invoice{} = invoice, opts, repo) do
    amount = Invoice.remaining_amount(invoice)

    case charge(locked, invoice, amount, opts[:description]) do
      {:ok, charge_result} ->
        record(locked, invoice, amount, charge_result, opts[:description], repo)

      {:error, reason} ->
        opts[:declined].(locked, reason)
    end
  end

  defp charge(%Subscription{payment_method: nil}, _invoice, _amount, _description) do
    {:error, :no_payment_method}
  end

  defp charge(%Subscription{payment_method: method} = subscription, invoice, amount, description) do
    with :ok <- ensure_chargeable(method, invoice) do
      method
      |> Providers.charge_payment_method(amount,
        currency: invoice.currency,
        description: description,
        invoice_uuid: invoice.uuid,
        idempotency_key: "#{invoice.uuid}-#{subscription.renewal_attempts}",
        metadata: %{invoice_uuid: invoice.uuid, subscription_uuid: subscription.uuid}
      )
      |> notify_refusal(invoice)
    end
  end

  defp notify_refusal({:error, reason} = refusal, invoice) do
    _ = Notifications.payment_failed(invoice, reason)
    refusal
  end

  defp notify_refusal(charged, _invoice), do: charged

  defp ensure_chargeable(%PaymentMethod{} = method, %Invoice{} = invoice) do
    cond do
      not PaymentMethod.usable?(method) -> {:error, :payment_method_not_usable}
      not Invoice.payable?(invoice) -> {:error, :invoice_not_payable}
      true -> :ok
    end
  end

  defp record(locked, invoice, amount, charge_result, description, repo) do
    # `charge_result` is a `%ChargeResult{}` struct and `provider_data` is a `:map`
    # column - the context sanitizes it, because a struct survives Ecto's cast and
    # dump and only blows up in the JSON encoder, i.e. after the card is charged.
    attrs = %{
      amount: amount,
      payment_method: locked.payment_method.provider,
      description: description,
      provider_transaction_id: charge_result.provider_transaction_id,
      provider_data: charge_result
    }

    case Billing.record_payment(invoice, attrs, nil) do
      {:ok, _transaction} ->
        with {:ok, renewed} <- next_period(locked, repo) do
          {:paid, renewed, amount}
        end

      {:error, reason} ->
        # The money LEFT the customer's account and the ledger has no row for it. The
        # refusal aborted this transaction, so only a rollback is left from here.
        Logger.error(
          "Charged #{amount} #{invoice.currency} for invoice #{invoice.invoice_number} " <>
            "but failed to record it: #{inspect(reason)}. Reconcile it by hand; it will " <>
            "not be retried."
        )

        repo.rollback({:charged_not_recorded, reason})
    end
  end

  defp next_period(%Subscription{subscription_type: plan} = subscription, repo) do
    next =
      SubscriptionType.next_billing_date(plan, DateTime.to_date(subscription.current_period_end))

    subscription
    |> Subscription.activate_changeset(DateTime.new!(next, ~T[00:00:00], "Etc/UTC"))
    |> repo.update()
  end
end
