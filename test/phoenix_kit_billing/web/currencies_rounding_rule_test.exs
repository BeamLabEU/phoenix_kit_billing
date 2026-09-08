defmodule PhoenixKitBilling.Web.CurrenciesRoundingRuleTest do
  @moduledoc """
  §5: the admin Currencies form offers the four `rounding_rule` values
  and saves the chosen one; a rejected rule (e.g. `charm_99` on a
  0-decimal currency) surfaces its changeset error on the form instead
  of silently persisting.
  """
  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.Test.Repo

  setup %{conn: conn} do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(Currency)

    {:ok, _} =
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

  test "the edit form offers the four rules and saves the chosen one", %{conn: conn, eur: eur} do
    {:ok, view, _html} = live(conn, "/en/admin/billing/currencies")

    view
    |> element(
      "button:not([role='menuitem'])[phx-click='show_edit_form'][phx-value-uuid='#{eur.uuid}']"
    )
    |> render_click()

    for v <- ~w(exact charm_99 charm_90 integer) do
      assert has_element?(view, "#currency-rounding-rule option[value='#{v}']")
    end

    view |> form("#currency-form", currency: %{rounding_rule: "charm_99"}) |> render_submit()

    assert PhoenixKitBilling.get_currency_by_code("EUR").rounding_rule == "charm_99"
    assert render(view) =~ "Charm .99"
  end

  test "a rejected rule stays on the form with its error", %{conn: conn, eur: eur} do
    {:ok, view, _html} = live(conn, "/en/admin/billing/currencies")

    view
    |> element(
      "button:not([role='menuitem'])[phx-click='show_edit_form'][phx-value-uuid='#{eur.uuid}']"
    )
    |> render_click()

    html =
      view
      |> form("#currency-form", currency: %{rounding_rule: "charm_99", decimal_places: "0"})
      |> render_submit()

    assert html =~ "two decimal places"
    assert PhoenixKitBilling.get_currency_by_code("EUR").rounding_rule == "exact"
  end
end
