defmodule PhoenixKitBilling.Workers.InvoiceEventWorker do
  @moduledoc """
  Delivers one invoice event to one handler. See
  `PhoenixKitBilling.InvoiceEvents` for the contract.

  Retries on `{:error, _}` (and on a raise) with Oban's backoff; cancels —
  does not retry — when the handler is no longer registered or the invoice
  no longer exists, because neither will fix itself.
  """

  use Oban.Worker,
    queue: :billing,
    max_attempts: 20,
    unique: [keys: [:event_uuid, :handler], period: :infinity]

  alias PhoenixKitBilling.InvoiceEvents

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event" => event, "invoice_uuid" => uuid, "handler" => name}}) do
    with {:ok, event} <- cast_event(event),
         {:ok, handler} <- InvoiceEvents.resolve_handler(name),
         %PhoenixKitBilling.Invoice{} = invoice <- PhoenixKitBilling.get_invoice(uuid) do
      case handler.handle_invoice_event(event, invoice) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_return, other}}
      end
    else
      :bad_event -> {:cancel, :unknown_event}
      :error -> {:cancel, :handler_not_registered}
      nil -> {:cancel, :invoice_not_found}
    end
  end

  defp cast_event(event) do
    case Enum.find(InvoiceEvents.events(), &(Atom.to_string(&1) == event)) do
      nil -> :bad_event
      atom -> {:ok, atom}
    end
  end
end
