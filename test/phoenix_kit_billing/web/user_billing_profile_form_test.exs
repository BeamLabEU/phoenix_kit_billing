defmodule PhoenixKitBilling.Web.UserBillingProfileFormTest do
  @moduledoc """
  The customer dashboard's billing profile form, mounted on the same paths as
  core's routes (`/dashboard/billing-profiles/new` and
  `/dashboard/billing-profiles/:uuid/edit`).

  Regression: the form read the profile from `params["id"]` while core routes
  the edit page with `:uuid`, so "Edit" opened an empty "New Billing Profile"
  form and saving it created a duplicate.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    {:ok, conn: put_test_scope(conn, scope), user: user}
  end

  defp profile_for(user, attrs \\ %{}) do
    {:ok, profile} =
      Billing.create_billing_profile(
        user.uuid,
        Map.merge(
          %{
            "type" => "individual",
            "first_name" => "Olena",
            "last_name" => "Koval",
            "email" => "olena@example.com",
            "country" => "UA",
            "city" => "Poltava"
          },
          attrs
        )
      )

    profile
  end

  test "the edit route opens the profile, not a new one", %{conn: conn, user: user} do
    profile = profile_for(user)

    {:ok, view, html} = live(conn, "/en/dashboard/billing-profiles/#{profile.uuid}/edit")

    assert html =~ "Edit Billing Profile"
    refute html =~ "New Billing Profile"
    assert has_element?(view, "input[name='billing_profile[first_name]'][value='Olena']")
    assert has_element?(view, "input[name='billing_profile[last_name]'][value='Koval']")
  end

  test "saving the edit form updates the profile instead of creating one", %{
    conn: conn,
    user: user
  } do
    profile = profile_for(user)

    {:ok, view, _html} = live(conn, "/en/dashboard/billing-profiles/#{profile.uuid}/edit")

    view
    |> form("form[phx-submit=save]", billing_profile: %{"first_name" => "Oksana"})
    |> render_submit()

    assert [saved] = Billing.list_user_billing_profiles(user.uuid)
    assert saved.uuid == profile.uuid
    assert saved.first_name == "Oksana"
    assert saved.last_name == "Koval"
  end

  test "another user's profile is not opened for editing", %{conn: conn} do
    other = fixture_user()
    profile = profile_for(other)

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, "/en/dashboard/billing-profiles/#{profile.uuid}/edit")

    assert to =~ "/dashboard/billing-profiles"
  end

  test "the new route still opens an empty form", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/dashboard/billing-profiles/new")

    assert html =~ "New Billing Profile"
  end
end
