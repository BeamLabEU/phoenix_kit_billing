defmodule PhoenixKitBilling.CurrencyRateAgeTest do
  @moduledoc """
  §6.2: `rate_updated_at` dates the RATE, not the row. `updated_at` moves
  when a symbol or a sort order changes, so it cannot stand in for this.
  """
  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling.Currency

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(Currency)

    {:ok, usd} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    %{usd: usd, eur: eur}
  end

  test "creating a currency dates its rate", %{eur: eur} do
    assert %DateTime{} = eur.rate_updated_at
  end

  test "changing the rate re-dates it", %{eur: eur} do
    old = eur.rate_updated_at

    Repo.update_all(Ecto.Query.from(c in Currency, where: c.code == "EUR"),
      set: [rate_updated_at: DateTime.add(old, -10 * 86_400, :second)]
    )

    PhoenixKit.Cache.clear(:billing_currencies)

    {:ok, updated} =
      PhoenixKitBilling.update_currency(PhoenixKitBilling.get_currency_by_code("EUR"), %{
        exchange_rate: "0.95"
      })

    assert DateTime.compare(updated.rate_updated_at, DateTime.add(old, -86_400, :second)) == :gt
  end

  test "changing anything BUT the rate leaves the date alone (§6.2)", %{eur: eur} do
    stale =
      eur.rate_updated_at |> DateTime.add(-40 * 86_400, :second) |> DateTime.truncate(:second)

    Repo.update_all(Ecto.Query.from(c in Currency, where: c.code == "EUR"),
      set: [rate_updated_at: stale]
    )

    PhoenixKit.Cache.clear(:billing_currencies)

    {:ok, updated} =
      PhoenixKitBilling.update_currency(PhoenixKitBilling.get_currency_by_code("EUR"), %{
        symbol: "€€",
        sort_order: 7
      })

    assert DateTime.compare(updated.rate_updated_at, stale) == :eq
  end

  test "writing the same rate again does not re-date it" do
    eur = PhoenixKitBilling.get_currency_by_code("EUR")
    {:ok, first} = PhoenixKitBilling.update_currency(eur, %{exchange_rate: "0.909091"})
    assert DateTime.compare(first.rate_updated_at, eur.rate_updated_at) == :eq
  end

  test "set_default_currency/1 dates every rate it renormalizes", %{eur: eur} do
    {:ok, _} = PhoenixKitBilling.set_default_currency(eur)

    for code <- ["USD", "EUR"] do
      assert %DateTime{} = PhoenixKitBilling.get_currency_by_code(code).rate_updated_at
    end
  end
end
