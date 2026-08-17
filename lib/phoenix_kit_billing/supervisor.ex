defmodule PhoenixKitBilling.Supervisor do
  @moduledoc """
  Supervisor for PhoenixKit Billing system.

  Manages billing background processes. Add to your application's supervision tree:

      # In lib/your_app/application.ex
      children = [
        PhoenixKitBilling.Supervisor
      ]
  """

  use Supervisor

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  alias PhoenixKitBilling.ApplicationIntegration
  alias PhoenixKitBilling.CoreCompat

  def init(_opts) do
    ApplicationIntegration.register()
    # Names any core API this package expects and the resolved phoenix_kit does
    # not provide. mix.exs admits core up to 3.0.0, so this is where a host that
    # upgraded past what billing understands finds out — once, by name.
    CoreCompat.log_check()
    Supervisor.init([], strategy: :one_for_one)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end
end
