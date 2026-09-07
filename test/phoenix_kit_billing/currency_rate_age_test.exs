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

  # A rate equal to the schema's own default ("1.0") never registers as a
  # changeset CHANGE against a brand new `%Currency{}` struct (whose
  # `exchange_rate` field already defaults to that same value) — so a
  # naive "only stamp on fetch_change" rule silently skips this insert.
  # Two real callers hit exactly this: the bulk import (always passes
  # "1.0") and the add-currency form (pre-filled at the default).
  test "creating a currency with the default rate '1.0' still stamps a date" do
    {:ok, currency} =
      PhoenixKitBilling.create_currency(%{
        code: "GBP",
        name: "Pound",
        symbol: "£",
        exchange_rate: "1.0"
      })

    assert %DateTime{} = currency.rate_updated_at
  end

  test "creating a currency in the exact shape the bulk import uses stamps a date" do
    {:ok, currency} =
      PhoenixKitBilling.create_currency(%{
        code: "JPY",
        name: "Yen",
        symbol: "¥",
        decimal_places: 0,
        exchange_rate: "1.0",
        enabled: false
      })

    assert %DateTime{} = currency.rate_updated_at
  end

  defp backdate(code, days) do
    stale_at =
      DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

    Repo.update_all(Ecto.Query.from(c in Currency, where: c.code == ^code),
      set: [rate_updated_at: stale_at]
    )

    PhoenixKit.Cache.clear(:billing_currencies)
    stale_at
  end

  # §6.2's own moduledoc scenario: re-promoting the currency that is
  # ALREADY default (e.g. a one-off task fixing a drifted base rate back
  # to exactly 1.0) divides every OTHER row's rate by 1 — the identity —
  # so nothing numerically moves anywhere and nothing should be re-dated.
  test "re-promoting the already-default currency leaves every rate_updated_at untouched" do
    stale_usd = backdate("USD", 40)
    stale_eur = backdate("EUR", 40)

    {:ok, _} =
      PhoenixKitBilling.set_default_currency(PhoenixKitBilling.get_currency_by_code("USD"))

    assert DateTime.compare(
             PhoenixKitBilling.get_currency_by_code("USD").rate_updated_at,
             stale_usd
           ) ==
             :eq

    assert DateTime.compare(
             PhoenixKitBilling.get_currency_by_code("EUR").rate_updated_at,
             stale_eur
           ) ==
             :eq
  end

  test "promoting a genuinely different currency dates every row it renormalizes" do
    stale_usd = backdate("USD", 40)
    stale_eur = backdate("EUR", 40)

    {:ok, _} =
      PhoenixKitBilling.set_default_currency(PhoenixKitBilling.get_currency_by_code("EUR"))

    assert DateTime.compare(
             PhoenixKitBilling.get_currency_by_code("USD").rate_updated_at,
             stale_usd
           ) ==
             :gt

    assert DateTime.compare(
             PhoenixKitBilling.get_currency_by_code("EUR").rate_updated_at,
             stale_eur
           ) ==
             :gt
  end

  test "rate_updated_at passed in attrs is ignored — the stamping helper is the only writer" do
    eur = PhoenixKitBilling.get_currency_by_code("EUR")

    forged =
      DateTime.utc_now() |> DateTime.add(-9999 * 86_400, :second) |> DateTime.truncate(:second)

    {:ok, updated} = PhoenixKitBilling.update_currency(eur, %{rate_updated_at: forged})

    assert DateTime.compare(updated.rate_updated_at, eur.rate_updated_at) == :eq
  end
end
