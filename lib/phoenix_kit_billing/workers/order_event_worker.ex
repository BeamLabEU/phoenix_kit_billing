defmodule PhoenixKitBilling.Workers.OrderEventWorker do
  @moduledoc """
  Delivers one order event to one handler. See `PhoenixKitBilling.OrderEvents`
  for the contract.

  Retries on `{:error, _}` (and on a raise) with Oban's backoff; cancels - does
  not retry - when the handler is no longer registered or the order no longer
  exists, because neither will fix itself. A handler with no clause for
  `:reinstated` (written before that event) is skipped for it, not retried.
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
      case deliver(handler, event, order) do
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

  # `:reinstated` came after handlers with clauses for the first three events
  # only: their own `handle_order_event/2` finding no clause for it means "not
  # interested", not a failure to retry twenty times. Any other raise, and a
  # missing clause for an older event, still fails the job.
  defp deliver(handler, :reinstated, order) do
    handler.handle_order_event(:reinstated, order)
  rescue
    e in FunctionClauseError ->
      if e.module == handler and e.function == :handle_order_event and e.arity == 2,
        do: :ok,
        else: reraise(e, __STACKTRACE__)
  end

  defp deliver(handler, event, order), do: handler.handle_order_event(event, order)

  defp cast_event(event) do
    case Enum.find(OrderEvents.events(), &(Atom.to_string(&1) == event)) do
      nil -> :bad_event
      atom -> {:ok, atom}
    end
  end
end
