defmodule PhoenixKitBilling.CurrencyPresentTest do
  @moduledoc """
  `PhoenixKitBilling.Currency.present/3` — the one place a base-currency
  amount becomes a display-currency amount (§4.3, §12), and
  `effective_rate/2` — the multiplier a cart freezes at creation (§4.4).

  Integration-tagged via `PhoenixKitBilling.DataCase`; excluded when the
  DataCase database is unavailable (see `test/test_helper.exs`). In this
  container the Sandbox pool currently cannot be enabled after
  `PhoenixKit.Migration.ensure_current/2` runs (pre-existing, unrelated
  to this task, same limitation Э0-B2's `e0b2_verify.exs` and Э1-B2's
  `e1b2_verify.exs` worked around), so these scenarios are ALSO verified
  against a real connection outside ExUnit via a scratch `mix run`
  script (`e1b3_verify.exs`) — all scenarios passed against
  `decor3dprint_test` on 2026-09-06.
  """

  use PhoenixKitBilling.DataCase, async: false

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

    {:ok, _jpy} =
      PhoenixKitBilling.create_currency(%{
        code: "JPY",
        name: "Yen",
        symbol: "¥",
        decimal_places: 0,
        exchange_rate: "150.0"
      })

    on_exit(fn -> Currency.put_request_currency(nil) end)
    :ok
  end

  test "converts a base amount to the display currency with one rounding by decimal_places" do
    assert Decimal.equal?(Currency.present(Decimal.new("138.00"), "EUR"), Decimal.new("125.45"))
    assert Decimal.equal?(Currency.present(Decimal.new("19.99"), "EUR"), Decimal.new("18.17"))
    assert Decimal.equal?(Currency.present(Decimal.new("19.99"), "JPY"), Decimal.new("2999"))
  end

  test "base, nil and unusable codes return the amount untouched" do
    for code <- ["USD", nil, "GBP", "XXX"] do
      assert Decimal.equal?(Currency.present(Decimal.new("138.00"), code), Decimal.new("138.00"))
    end
  end

  test ":rate uses the frozen cart rate instead of the table (§12.2)" do
    assert Decimal.equal?(
             Currency.present(Decimal.new("138.00"), "EUR", rate: Decimal.new("0.95")),
             Decimal.new("131.10")
           )

    Repo.update_all(Ecto.Query.from(c in Currency, where: c.code == "EUR"),
      set: [exchange_rate: Decimal.new("0.5")]
    )

    assert Decimal.equal?(
             Currency.present(Decimal.new("138.00"), "EUR", rate: Decimal.new("0.909091")),
             Decimal.new("125.45")
           )
  end

  test "effective_rate/2 is target over base, six decimals" do
    usd = PhoenixKitBilling.get_currency_by_code("USD")
    eur = PhoenixKitBilling.get_currency_by_code("EUR")
    assert Decimal.equal?(Currency.effective_rate(eur, usd), Decimal.new("0.909091"))
  end

  test "present/3 resolves on every call — a rate change shows on the next call (§4.2.1)" do
    a = Currency.present(Decimal.new("138.00"), "EUR")
    eur = PhoenixKitBilling.get_currency_by_code("EUR")
    {:ok, _} = PhoenixKitBilling.update_currency(eur, %{exchange_rate: "0.95"})
    b = Currency.present(Decimal.new("138.00"), "EUR")
    refute Decimal.equal?(a, b)
  end
end
