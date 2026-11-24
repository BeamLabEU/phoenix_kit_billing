defmodule PhoenixKitBilling.Web.UserBillingProfilesTest do
  @moduledoc """
  The customer's billing profile list writes each profile's type
  ("Individual" / "Company") in the reader's language.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

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

  defp type_badges(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#profiles-list span.badge-primary, #profiles-list span.badge-secondary")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    |> Enum.sort()
  end

  for {locale, labels} <- [
        {"en", ["Company", "Individual"]},
        {"de", ["Privatperson", "Unternehmen"]},
        {"fr", ["Entreprise", "Particulier"]}
      ] do
    test "profile types read in #{locale}", %{conn: conn} do
      {:ok, _view, html} =
        live(put_test_locale(conn, unquote(locale)), "/en/dashboard/billing-profiles")

      assert type_badges(html) == unquote(labels)
    end
  end
end
