defmodule PhoenixKitBilling.OrderPayment do
  @moduledoc """
  Starts the online payment of an order: finds or creates the order's open
  invoice, makes it payable and opens a checkout session at the provider of
  the order's payment option.

  The public entry point is `PhoenixKitBilling.start_order_payment/2`; this
  module only composes billing's own public functions
  (`create_invoice_from_order/2`, `send_invoice/2`, `create_checkout_session/3`),
  so their errors reach the caller as they are.

  ## Steps

    1. The order must be unpaid and carry an online payment option whose
       provider is configured.
    2. The order's open invoice (`draft`, `sent` or `overdue`, newest first)
       is reused, or one is created from the order. Steps 2 to 4 run under a
       per-order advisory lock (held on one connection, outside any
       transaction, so billing's invoice events still follow their commits),
       so two clicks cannot create two invoices or two live sessions.
    3. A `draft` invoice is sent **without an email** (`send_email: false`):
       only a `sent` or `overdue` invoice is payable, and the buyer is
       emailed when the payment lands, not when the checkout opens.
    4. A checkout session recorded on the invoice (`metadata["checkout"]`)
       for the same provider is reused while it is younger than one hour;
       otherwise a new one is opened and recorded. The payment itself is
       confirmed by the provider's webhook, never by the return URL.

  ## Options

    * `:success_url` (required) - where the provider sends the buyer after paying
    * `:cancel_url` - defaults to `:success_url`
    * `:customer_email` - the invoice recipient (when it differs from the
      order's buyer) and the address prefilled at the provider
    * `:provider` - overrides the provider of the order's payment option

  Returns `{:ok, %{invoice: invoice, url: url}}` or `{:error, reason}`, where
  the reason is one of `:order_not_found`, `:order_not_payable` (cancelled,
  refunded, no online payment option), `:already_paid`,
  `:provider_not_available`, or whatever billing's own functions return.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Order, PaymentOption, Providers}

  # Stripe keeps a Checkout session for at least 30 minutes and up to 24
  # hours; one hour is short enough to be live on every provider we know.
  @session_reuse_seconds 3600

  @spec start(Order.t() | String.t(), keyword()) ::
          {:ok, %{invoice: %Invoice{}, url: String.t()}} | {:error, term()}
  def start(order_or_uuid, opts) do
    success_url = Keyword.fetch!(opts, :success_url)
    opts = Keyword.put_new(opts, :cancel_url, success_url)

    with {:ok, order} <- load_order(order_or_uuid) do
      # Everything from "which invoice" to "the session is recorded" runs under
      # the order's lock, so two clicks cannot open two sessions for one
      # invoice. It is a session-level lock on one pinned connection and no
      # transaction: the invoice events billing broadcasts while creating and
      # sending the invoice must go out after their own commits.
      with_order_lock(order, fn -> start_locked(order, opts) end)
    end
  end

  defp start_locked(order, opts) do
    # Re-read under the lock: the order may have been paid while we waited.
    with {:ok, order} <- load_order(order.uuid),
         :ok <- ensure_payable(order),
         {:ok, provider} <- resolve_provider(order, opts),
         {:ok, invoice} <- find_or_create_invoice(order),
         {:ok, invoice} <- make_payable(invoice, opts),
         {:ok, url} <- session_url(invoice, provider, opts) do
      {:ok, %{invoice: repo().get!(Invoice, invoice.uuid), url: url}}
    end
  end

  defp load_order(%Order{uuid: uuid}), do: load_order(uuid)

  defp load_order(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} ->
        case repo().get(Order, uuid) do
          nil -> {:error, :order_not_found}
          order -> {:ok, repo().preload(order, :payment_option)}
        end

      :error ->
        {:error, :order_not_found}
    end
  end

  defp ensure_payable(%Order{status: "paid"}), do: {:error, :already_paid}

  defp ensure_payable(%Order{status: status}) when status in ~w(draft pending confirmed),
    do: :ok

  defp ensure_payable(_order), do: {:error, :order_not_payable}

  defp resolve_provider(%Order{payment_option: option}, opts) do
    case {opts[:provider], option} do
      {provider, _} when not is_nil(provider) -> known_provider(provider)
      {nil, %PaymentOption{type: "online", provider: provider}} -> known_provider(provider)
      _ -> {:error, :order_not_payable}
    end
  end

  # A name that is not one of the providers billing knows must not create an
  # atom, and one that is not configured must not open an invoice.
  defp known_provider(name) do
    provider = Enum.find(Providers.all_providers(), &(to_string(&1) == to_string(name)))

    if provider && Providers.provider_enabled?(provider),
      do: {:ok, provider},
      else: {:error, :provider_not_available}
  end

  defp with_order_lock(%Order{uuid: uuid}, fun) do
    repo().checkout(fn ->
      key = "billing_order_payment:" <> uuid
      repo().query!("SELECT pg_advisory_lock(hashtext($1))", [key])

      try do
        fun.()
      after
        repo().query!("SELECT pg_advisory_unlock(hashtext($1))", [key])
      end
    end)
  end

  defp find_or_create_invoice(order) do
    open =
      from(i in Invoice,
        where: i.order_uuid == ^order.uuid and i.status in ~w(draft sent overdue paid),
        order_by: [desc: i.inserted_at, desc: i.uuid],
        limit: 1
      )

    case repo().one(open) do
      %Invoice{status: "paid"} -> {:error, :already_paid}
      %Invoice{} = invoice -> {:ok, invoice}
      nil -> Billing.create_invoice_from_order(order)
    end
  end

  defp make_payable(%Invoice{status: "draft"} = invoice, opts) do
    send_opts = ([send_email: false] ++ Keyword.take(opts, [:customer_email])) |> to_email()

    case Billing.send_invoice(invoice, send_opts) do
      {:ok, sent, _email_result} -> {:ok, sent}
      {:error, _} = error -> error
    end
  end

  defp make_payable(invoice, _opts), do: {:ok, invoice}

  defp to_email(opts) do
    case Keyword.pop(opts, :customer_email) do
      {nil, opts} -> opts
      {email, opts} -> Keyword.put(opts, :to_email, email)
    end
  end

  defp session_url(invoice, provider, opts) do
    case reusable_url(invoice, provider) do
      url when is_binary(url) ->
        {:ok, url}

      nil ->
        checkout_opts = Keyword.take(opts, [:success_url, :cancel_url, :customer_email])
        Billing.create_checkout_session(invoice, provider, checkout_opts)
    end
  end

  defp reusable_url(%Invoice{metadata: %{"checkout" => %{"url" => url} = checkout}}, provider)
       when is_binary(url) do
    with true <- checkout["provider"] == to_string(provider),
         {:ok, created_at, _} <- DateTime.from_iso8601(checkout["created_at"] || ""),
         true <- DateTime.diff(DateTime.utc_now(), created_at) < @session_reuse_seconds do
      url
    else
      _ -> nil
    end
  end

  defp reusable_url(_invoice, _provider), do: nil

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
