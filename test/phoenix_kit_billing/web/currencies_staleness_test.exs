defmodule PhoenixKitBilling.Web.CurrenciesStalenessTest do
  @moduledoc """
  §6.2: the admin Currencies page warns about stale rates without ever
  hiding or blocking them — a banner naming the stale code(s) above the
  table, and a badge on the affected row, only when at least one
  currency's rate is actually stale.
  """
  use PhoenixKitBilling.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.Test.Repo

  setup %{conn: conn} do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(Currency)

    {:ok, _usd} =
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

    %{conn: put_test_scope(conn, fake_scope()), eur: eur}
  end

  defp backdate(code, days) do
    stale_at =
      DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(c in Currency, where: c.code == ^code),
      set: [rate_updated_at: stale_at]
    )

    PhoenixKit.Cache.clear(:billing_currencies)
    stale_at
  end

  test "a stale rate shows the banner naming it and a row badge", %{conn: conn} do
    PhoenixKit.Settings.update_setting("fx_rate_max_age_days", "30")
    backdate("EUR", 40)

    {:ok, view, html} = live(conn, "/en/admin/billing/currencies")

    assert html =~ ~s(id="currencies-stale-banner")
    assert has_element?(view, "#currencies-stale-banner", "EUR")
    assert has_element?(view, "#currencies-table span", "out of date")
  end

  test "no banner or badge while every rate is fresh", %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/billing/currencies")

    refute html =~ "currencies-stale-banner"
    refute has_element?(view, "#currencies-stale-banner")
    refute has_element?(view, "#currencies-table span", "out of date")
  end
end
