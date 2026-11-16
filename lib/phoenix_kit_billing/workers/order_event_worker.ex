defmodule PhoenixKitBilling.Workers.OrderEventWorker do
  @moduledoc """
  Delivers one order event to one handler. See `PhoenixKitBilling.OrderEvents`
  for the contract.

  Retries on `{:error, _}` (and on a raise) with Oban's backoff; cancels - does
  not retry - when the handler is no longer registered or the order no longer
  exists, because neither will fix itself.
  """

  use Oban.Worker,
    queue: :billing,
    max_attempts: 20,
    unique: [keys: [:event_uuid, :handler], period: :infinity]

  alias PhoenixKitBilling.OrderEvents

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event" => event, "order_uuid" => uuid, "handler" => name}}) do
    with {:ok, event} <- cast_event(event),
         {:ok, handler} <- OrderEvents.resolve_handler(name),
         %PhoenixKitBilling.Order{} = order <- PhoenixKitBilling.get_order(uuid) do
      case handler.handle_order_event(event, order) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_return, other}}
      end
    else
      :bad_event -> {:cancel, :unknown_event}
      :error -> {:cancel, :handler_not_registered}
      nil -> {:cancel, :order_not_found}
    end
  end

  defp cast_event(event) do
    case Enum.find(OrderEvents.events(), &(Atom.to_string(&1) == event)) do
      nil -> :bad_event
      atom -> {:ok, atom}
    end
  end
end
