defmodule PhoenixKitBilling.Test.StaticFxRateProvider do
  @moduledoc """
  Test double for the `:fx_rate_provider` MFA hook
  (`PhoenixKitBilling.refresh_rates_from_provider/1`). A test configures
  the function to run via `set/1`, then points
  `config :phoenix_kit, :fx_rate_provider` at `{__MODULE__, :fetch}` —
  `fetch/0` looks the function up from THIS process's dictionary, so it
  only works called from the same process that configured it (true for
  every test here: the provider is invoked synchronously, not from a
  spawned process).
  """

  @key :phoenix_kit_billing_test_fx_provider_fun

  @spec set((-> term())) :: :ok
  def set(fun) when is_function(fun, 0) do
    Process.put(@key, fun)
    :ok
  end

  @spec fetch() :: term()
  def fetch, do: Process.get(@key).()
end
