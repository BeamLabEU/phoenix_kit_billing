defmodule PhoenixKitBilling.InvoiceEvents do
  @moduledoc """
  A durable way for OTHER modules to learn that an invoice was paid,
  refunded or voided.

  Billing always recorded a payment durably, but told the rest of the
  system only through `Phoenix.PubSub` — a notification, not a delivery: a
  listener that was restarting when the webhook landed never heard, and the
  thing the invoice paid for (a booking, an order) stayed unpaid while the
  money sat in billing. Worse, `{:invoice_paid, _}` was only ever broadcast
  by the admin *Mark paid* action — a payment that arrived through a
  provider webhook (`record_payment/3`) never announced itself at all.

  ## For a module that wants to hear

  Export `billing_invoice_event_handlers/0` from your `PhoenixKit.Module`,
  returning handler modules. Each implements:

      @spec handle_invoice_event(:paid | :refunded | :voided, PhoenixKitBilling.Invoice.t()) ::
              :ok | {:error, term()}

  Duck-typed — no compile-time dependency on billing — the same pattern as
  `ai_translatables/0`, so an optional billing integration costs nothing
  when billing is absent. A host app can also list handlers:

      config :phoenix_kit_billing, invoice_event_handlers: [MyApp.InvoiceHandler]

  ## Guarantees

  - The event is enqueued in the **same database transaction** that changed
    the invoice: it is committed with the payment or not at all.
  - **One Oban job per (event, handler)**: a failing handler retries alone
    and never holds up another module.
  - **At-least-once.** A handler must be idempotent; the job carries an
    `event_uuid` to key that on.
  - The handler receives the invoice **as it is now** — re-read when the
    job runs — not a snapshot from when it was enqueued.
  - A job may only call a handler that is registered *when it runs*: job
    arguments are data, never a license to invoke an arbitrary module.

  PubSub still fires for live admin screens, after the commit.
  """

  require Logger

  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Workers.InvoiceEventWorker

  @events [:paid, :refunded, :voided]

  @doc "The events handlers can receive."
  def events, do: @events

  @doc """
  Every registered handler: the host's configured ones plus those declared
  by installed PhoenixKit modules via `billing_invoice_event_handlers/0`.
  """
  def handlers do
    configured = Application.get_env(:phoenix_kit_billing, :invoice_event_handlers, [])

    (configured ++ discovered())
    |> Enum.uniq()
    |> Enum.filter(&handler?/1)
  end

  defp discovered do
    PhoenixKit.ModuleDiscovery.discover_external_modules()
    |> Enum.filter(fn mod ->
      Code.ensure_loaded?(mod) and function_exported?(mod, :billing_invoice_event_handlers, 0)
    end)
    |> Enum.flat_map(fn mod ->
      try do
        List.wrap(mod.billing_invoice_event_handlers())
      rescue
        e ->
          Logger.warning(
            "[Billing] #{inspect(mod)}.billing_invoice_event_handlers/0 failed: #{Exception.message(e)}"
          )

          []
      end
    end)
  rescue
    _ -> []
  end

  defp handler?(mod) when is_atom(mod),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, :handle_invoice_event, 2)

  defp handler?(_), do: false

  @doc """
  Enqueues one job per handler for `event` on `invoice`. Call it INSIDE the
  transaction that changed the invoice, so the event commits with it.

  If Oban is not running (a host misconfiguration, or a bare test), this
  logs and returns `:not_enqueued` rather than raising — a payment must
  never be rolled back because a notification could not be queued.
  """
  def enqueue(event, %Invoice{uuid: uuid}) when event in @events do
    event_uuid = Ecto.UUID.generate()

    Enum.each(handlers(), fn handler ->
      %{
        "event" => Atom.to_string(event),
        "invoice_uuid" => uuid,
        "event_uuid" => event_uuid,
        "handler" => inspect(handler)
      }
      |> InvoiceEventWorker.new()
      |> Oban.insert!()
    end)
  rescue
    e in [ArgumentError, RuntimeError] ->
      Logger.error(
        "[Billing] invoice #{event} event for #{uuid} NOT enqueued (is Oban running?): " <>
          Exception.message(e)
      )

      :not_enqueued
  end

  @doc false
  # Resolves a handler named in a job's arguments against the handlers
  # registered NOW. Never `String.to_existing_atom` + call: that would let
  # any string in a job row invoke any loaded module.
  def resolve_handler(name) when is_binary(name) do
    case Enum.find(handlers(), &(inspect(&1) == name)) do
      nil -> :error
      handler -> {:ok, handler}
    end
  end
end
