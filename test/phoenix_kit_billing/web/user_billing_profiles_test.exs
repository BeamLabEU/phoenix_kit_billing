defmodule PhoenixKitBilling.Web.UserBillingProfilesTest do
  @moduledoc """
  The customer's billing profile list writes each profile's type
  ("Individual" / "Company") in the reader's language.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  import Ecto.Query, only: [from: 2]

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.BillingProfile
  alias PhoenixKitBilling.Test.Repo

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)

    for attrs <- [
          %{"type" => "individual", "first_name" => "Olena", "last_name" => "Koval"},
          %{"type" => "company", "company_name" => "Koval Print"}
        ] do
      {:ok, _profile} =
        Billing.create_billing_profile(
          user.uuid,
          Map.merge(
            %{"email" => "olena@example.com", "country" => "EE", "city" => "Tallinn"},
            attrs
          )
        )
    end

    {:ok, conn: put_test_scope(conn, scope)}
  end

  # {company label, individual label}: the primary badge is a company's, the
  # secondary one an individual's, so a swapped mapping shows up as a swap.
  defp type_badges(html) do
    doc = html |> LazyHTML.from_fragment()

    text = fn selector ->
      doc |> LazyHTML.query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    end

    {text.("#profiles-list span.badge-primary"), text.("#profiles-list span.badge-secondary")}
  end

  for {locale, company, individual} <- [
        {"en", "Company", "Individual"},
        {"de", "Unternehmen", "Privatperson"},
        {"fr", "Entreprise", "Particulier"}
      ] do
    test "profile types read in #{locale}", %{conn: conn} do
      {:ok, _view, html} =
        live(put_test_locale(conn, unquote(locale)), "/en/dashboard/billing-profiles")

      assert type_badges(html) == {[unquote(company)], [unquote(individual)]}
    end
  end

  test "a type without a label shows as its capitalised value", %{conn: conn} do
    Repo.update_all(from(p in BillingProfile, where: p.type == "company"),
      set: [type: "partnership"]
    )

    {:ok, _view, html} =
      live(put_test_locale(conn, "de"), "/en/dashboard/billing-profiles")

    assert {[], secondary} = type_badges(html)
    assert Enum.sort(secondary) == ["Partnership", "Privatperson"]
  end
end
