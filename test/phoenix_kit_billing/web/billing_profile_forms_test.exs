defmodule PhoenixKitBilling.Web.BillingProfileFormsTest do
  @moduledoc """
  The dashboard and admin billing profile forms both render through
  `BillingProfileFields`. These tests drive the real LiveViews: the shared
  fields show up, the type switch and validation work, and a submit persists
  every field the shared form carries.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

  @admin_new "/en/admin/billing/profiles/new"
  @user_new "/en/dashboard/billing-profiles/new"

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    {:ok, conn: put_test_scope(conn, scope), user: user}
  end

  describe "dashboard form" do
    test "renders the shared fields, the type switch and the options", %{conn: conn} do
      {:ok, view, _html} = live(conn, @user_new)

      assert has_element?(view, "#user-billing-profile-form #billing-profile-first_name")
      assert has_element?(view, "#billing-profile-middle_name")
      assert has_element?(view, "#billing-profile-address_line2")
      assert has_element?(view, "#billing-profile-name")
      assert has_element?(view, "#billing-profile-is_default")
      refute has_element?(view, "#billing-profile-company_name")

      view |> element("#billing-profile-type-company") |> render_click()

      assert has_element?(view, "#billing-profile-company_name")
      refute has_element?(view, "#billing-profile-first_name")
    end

    test "validate shows the errors of the visible type", %{conn: conn} do
      {:ok, view, _html} = live(conn, @user_new)

      html =
        view
        |> form("#user-billing-profile-form", %{"billing_profile" => %{"first_name" => ""}})
        |> render_change()

      assert html =~ "is required for individuals"
    end

    test "switching to company validates the company rules", %{conn: conn} do
      {:ok, view, _html} = live(conn, @user_new)
      view |> element("#billing-profile-type-company") |> render_click()

      html =
        view
        |> form("#user-billing-profile-form", %{
          "billing_profile" => %{"type" => "company", "company_name" => ""}
        })
        |> render_change()

      assert html =~ "is required for companies"
    end

    test "submitting an individual creates the profile with middle name and address", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, @user_new)

      view
      |> form("#user-billing-profile-form", %{
        "billing_profile" => %{
          "first_name" => "Ada",
          "middle_name" => "Augusta",
          "last_name" => "Lovelace",
          "email" => "ada@example.com",
          "country" => "EE",
          "address_line1" => "Street 1",
          "address_line2" => "Flat 2",
          "city" => "Tallinn",
          "postal_code" => "10115"
        }
      })
      |> render_submit()

      assert_redirect(view)

      assert [profile] = Billing.list_user_billing_profiles(user.uuid)
      assert profile.type == "individual"
      assert profile.middle_name == "Augusta"
      assert profile.address_line2 == "Flat 2"
      assert profile.user_uuid == user.uuid
    end

    test "submitting a company creates a company profile", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @user_new)
      view |> element("#billing-profile-type-company") |> render_click()

      view
      |> form("#user-billing-profile-form", %{
        "billing_profile" => %{
          "company_name" => "Acme OÜ",
          "company_vat_number" => "ee123456789",
          "company_legal_address" => "Legal St 1",
          "country" => "EE"
        }
      })
      |> render_submit()

      assert_redirect(view)

      assert [profile] = Billing.list_user_billing_profiles(user.uuid)
      assert profile.type == "company"
      assert profile.company_name == "Acme OÜ"
      assert profile.company_vat_number == "EE123456789"
      assert profile.company_legal_address == "Legal St 1"
    end

    test "editing loads the saved values into the shared fields", %{conn: conn, user: user} do
      {:ok, profile} =
        Billing.create_billing_profile(user.uuid, %{
          "type" => "company",
          "company_name" => "Acme OÜ",
          "country" => "EE"
        })

      {:ok, view, _html} = live(conn, "/en/dashboard/billing-profiles/#{profile.uuid}/edit")

      assert has_element?(view, "#billing-profile-company_name[value='Acme OÜ']")
      assert has_element?(view, "#billing-profile-type-company[checked]")
    end

    test "returns to return_to after saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, @user_new <> "?return_to=/en/dashboard/billing-orders")

      view
      |> form("#user-billing-profile-form", %{
        "billing_profile" => %{
          "first_name" => "Ada",
          "last_name" => "Lovelace",
          "country" => "EE"
        }
      })
      |> render_submit()

      assert_redirect(view, "/en/dashboard/billing-orders")
    end

    test "saves the default flag", %{conn: conn, user: user} do
      {:ok, _first} =
        Billing.create_billing_profile(user.uuid, %{
          "first_name" => "First",
          "last_name" => "One",
          "country" => "EE"
        })

      {:ok, view, _html} = live(conn, @user_new)

      view
      |> form("#user-billing-profile-form", %{
        "billing_profile" => %{
          "first_name" => "Second",
          "last_name" => "Two",
          "country" => "EE",
          "is_default" => "true"
        }
      })
      |> render_submit()

      assert_redirect(view)

      second =
        Enum.find(Billing.list_user_billing_profiles(user.uuid), &(&1.first_name == "Second"))

      assert second.is_default
    end

    test "a failed save stays on the form with the errors and creates nothing", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, @user_new)

      html =
        view
        |> form("#user-billing-profile-form", %{
          "billing_profile" => %{"first_name" => "", "last_name" => "", "country" => "EE"}
        })
        |> render_submit()

      assert html =~ "is required for individuals"
      assert has_element?(view, "#user-billing-profile-form")
      assert Billing.list_user_billing_profiles(user.uuid) == []
    end

    test "renders the VAT and country errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, @user_new)
      view |> element("#billing-profile-type-company") |> render_click()

      html =
        render_change(view, "validate", %{
          "billing_profile" => %{
            "type" => "company",
            "company_name" => "Acme OÜ",
            "company_vat_number" => "!!",
            "country" => "EE"
          }
        })

      assert html =~ "must be a valid EU VAT number"

      html =
        render_change(view, "validate", %{
          "billing_profile" => %{
            "type" => "company",
            "company_name" => "Acme OÜ",
            "country" => "EST"
          }
        })

      assert html =~ "should be 2 character(s)"
    end
  end

  describe "admin form" do
    test "renders the shared fields and switches type", %{conn: conn} do
      {:ok, view, _html} = live(conn, @admin_new)

      assert has_element?(view, "#billing-profile-first_name")
      assert has_element?(view, "#billing-profile-middle_name")
      assert has_element?(view, "#billing-profile-is_default")

      view |> element("#billing-profile-type-company") |> render_click()

      assert has_element?(view, "#billing-profile-company_name")
      refute has_element?(view, "#billing-profile-first_name")
    end

    test "validate shows the field errors inline", %{conn: conn} do
      {:ok, view, _html} = live(conn, @admin_new)

      html =
        view
        |> form("#admin-billing-profile-form", %{
          "billing_profile" => %{"first_name" => "", "email" => "not-an-email"}
        })
        |> render_change()

      assert html =~ "is required for individuals"
      assert html =~ "must be a valid email address"
    end

    test "saving creates the profile for the selected user", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, @admin_new)

      render_change(view, "select_user", %{"user_uuid" => user.uuid})

      view
      |> form("#admin-billing-profile-form", %{
        "billing_profile" => %{
          "first_name" => "Grace",
          "last_name" => "Hopper",
          "country" => "EE"
        }
      })
      |> render_submit()

      assert_redirect(view)

      assert [profile] = Billing.list_user_billing_profiles(user.uuid)
      assert profile.first_name == "Grace"
      assert profile.name == "Grace Hopper"
    end

    test "editing updates the profile", %{conn: conn, user: user} do
      {:ok, profile} =
        Billing.create_billing_profile(user.uuid, %{
          "first_name" => "Grace",
          "last_name" => "Hopper",
          "country" => "EE"
        })

      {:ok, view, _html} = live(conn, "/en/admin/billing/profiles/#{profile.uuid}/edit")

      assert has_element?(view, "#billing-profile-first_name[value=Grace]")

      view
      |> form("#admin-billing-profile-form", %{
        "billing_profile" => %{"first_name" => "Amazing", "middle_name" => "Brewster"}
      })
      |> render_submit()

      assert_redirect(view)

      updated = Billing.get_billing_profile(profile.uuid)
      assert updated.first_name == "Amazing"
      assert updated.middle_name == "Brewster"
    end

    test "a failed save stays on the form with the errors and creates nothing", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, @admin_new)
      render_change(view, "select_user", %{"user_uuid" => user.uuid})

      html =
        view
        |> form("#admin-billing-profile-form", %{
          "billing_profile" => %{"first_name" => "", "email" => "nope", "country" => "EE"}
        })
        |> render_submit()

      assert html =~ "is required for individuals"
      assert html =~ "must be a valid email address"
      assert Billing.list_user_billing_profiles(user.uuid) == []
    end

    test "renders the VAT and country errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, @admin_new)
      view |> element("#billing-profile-type-company") |> render_click()

      html =
        render_change(view, "validate", %{
          "billing_profile" => %{
            "type" => "company",
            "company_name" => "Acme OÜ",
            "company_vat_number" => "!!",
            "country" => "EE"
          }
        })

      assert html =~ "must be a valid EU VAT number"

      html =
        render_change(view, "validate", %{
          "billing_profile" => %{
            "type" => "company",
            "company_name" => "Acme OÜ",
            "country" => "EST"
          }
        })

      assert html =~ "should be 2 character(s)"
    end
  end
end
