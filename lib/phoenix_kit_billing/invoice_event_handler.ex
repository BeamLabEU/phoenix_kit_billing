defmodule PhoenixKitBilling.InvoiceEventHandler do
  @moduledoc """
  The contract of a durable invoice-event handler (`PhoenixKitBilling.InvoiceEvents`).

  Declaring it is optional - handlers are found by duck typing, so a module that
  must not depend on billing at compile time just defines
  `handle_invoice_event/2`. A module that already depends on billing can declare
  the behaviour and have the compiler check the function:

      defmodule MyBookings.InvoicePaid do
        @behaviour PhoenixKitBilling.InvoiceEventHandler

        @impl true
        def handle_invoice_event(:paid, invoice) do
          # Idempotent: confirming an already confirmed booking is a no-op.
          MyBookings.confirm_paid(invoice.metadata["booking_uuid"])
        end

        def handle_invoice_event(_event, _invoice), do: :ok
      end

  and register it from its `PhoenixKit.Module`:

      def billing_invoice_event_handlers, do: [MyBookings.InvoicePaid]

  or from the host: `config :phoenix_kit_billing, invoice_event_handlers: [...]`.

  The function gets the invoice as it is when the job runs, not when the event
  happened, at least once. `:ok` finishes the job; `{:error, reason}` or a raise
  retries it with backoff (up to 20 attempts). End with a catch-all clause: new
  events can be added, and an event with no clause fails its job.
  """

  @typedoc "The events a handler can receive (`PhoenixKitBilling.InvoiceEvents.events/0`)."
  @type event :: :paid | :refunded | :voided

  @callback handle_invoice_event(event(), PhoenixKitBilling.Invoice.t()) ::
              :ok | {:error, term()}
end
