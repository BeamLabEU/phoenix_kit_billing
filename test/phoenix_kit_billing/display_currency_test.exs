defmodule PhoenixKitBilling.DisplayCurrencyTest do
  @moduledoc """
  `PhoenixKitBilling.get_base_currency/0`, `get_display_currency/0`, and
  `resolve_display_currency/1` — the §6.3 fail-safe resolution between the
  shop's base currency and the request-scoped display code (§4.2).

  Integration-tagged via `PhoenixKitBilling.DataCase`; excluded when the
  DataCase database is unavailable (see `test/test_helper.exs`). An
  earlier revision of this suite could not get the Sandbox pool enabled
  in this container and worked around it with a scratch `mix run` script
  (`e1b2_verify.exs`) run outside ExUnit; the maintainer's `cc3a6b0`
  (applying billing's own migration chain before `Sandbox.mode/2` in
  `test_helper.exs`) superseded that — this DataCase suite runs directly.
  """

  use PhoenixKitBilling.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitBilling.Currency

  setup do
    Repo.delete_all(Currency)

    {:ok, _usd} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    {:ok, _gbp} =
      PhoenixKitBilling.create_currency(%{
        code: "GBP",
        name: "Pound",
        symbol: "£",
        enabled: false,
        exchange_rate: "0.772727"
      })

    on_exit(fn -> Currency.put_request_currency(nil) end)
    :ok
  end

  test "no request currency -> base, no log" do
    Currency.put_request_currency(nil)

    log =
      capture_log(fn ->
        assert %{code: "USD"} = PhoenixKitBilling.get_display_currency()
      end)

    assert log == ""
  end

  test "mapped, enabled, positive rate -> that currency" do
    Currency.put_request_currency("EUR")
    assert %{code: "EUR"} = PhoenixKitBilling.get_display_currency()
  end

  test "disabled currency -> base + exactly one warning per process" do
    Currency.put_request_currency("GBP")

    log =
      capture_log(fn ->
        assert %{code: "USD"} = PhoenixKitBilling.get_display_currency()
        assert %{code: "USD"} = PhoenixKitBilling.get_display_currency()
      end)

    assert length(Regex.scan(~r/GBP/, log)) == 1
  end

  test "unknown code and non-positive rate fall back to base with a warning" do
    Repo.update_all(
      Ecto.Query.from(c in Currency, where: c.code == "EUR"),
      set: [exchange_rate: Decimal.new("0")]
    )

    assert capture_log(fn ->
             assert %{code: "USD"} = PhoenixKitBilling.resolve_display_currency("EUR")
           end) =~ "EUR"

    assert capture_log(fn ->
             assert %{code: "USD"} = PhoenixKitBilling.resolve_display_currency("XXX")
           end) =~ "XXX"
  end

  test "get_base_currency/0 never depends on the request override" do
    Currency.put_request_currency("EUR")
    assert %{code: "USD"} = PhoenixKitBilling.get_base_currency()
  end
end
