defmodule PhoenixKitBilling.Web.HeaderTrailTest do
  @moduledoc """
  The admin header breadcrumb is drawn by core from four socket assigns —
  `page_section` (+ `_path`), `page_crumbs` and `page_title` — and every
  billing page sets them through `PhoenixKitBilling.Web.Trail`. The test
  layout does not render the header, so these read the assigns off the
  mounted LiveView and pin the shapes core's admin-header guide requires:
  the landing page has no section, list pages carry the module, record
  pages carry their list, edit pages carry the record, and the settings
  pages live under Settings.
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

  defp trail(conn, path) do
    {:ok, view, _html} = live(conn, path)
    assigns = :sys.get_state(view.pid).socket.assigns

    %{
      section: assigns[:page_section],
      section_path: assigns[:page_section_path],
      crumbs: assigns[:page_crumbs],
      title: assigns[:page_title]
    }
  end

  test "the landing page is titled by the module and has no section", %{conn: conn} do
    assert %{section: nil, crumbs: [], title: "Billing"} = trail(conn, "/en/admin/billing")
  end

  test "a list page carries the module as its section", %{conn: conn} do
    assert %{section: "Billing", section_path: path, crumbs: [], title: "Orders"} =
             trail(conn, "/en/admin/billing/orders")

    assert path =~ "/admin/billing"
  end

  test "an order's pages carry the list, then the order", %{conn: conn, user: user} do
    {:ok, order} =
      Billing.create_order(%{
        "user_uuid" => user.uuid,
        "currency" => "EUR",
        "total" => Decimal.new("10.00"),
        "billing_snapshot" => %{"email" => user.email}
      })

    assert %{section: "Billing", crumbs: [%{label: "Orders", path: list}], title: title} =
             trail(conn, "/en/admin/billing/orders/#{order.uuid}")

    assert title == order.order_number
    assert list =~ "/admin/billing/orders"

    assert %{crumbs: [%{label: "Orders"}, %{label: number, path: detail}], title: "Edit"} =
             trail(conn, "/en/admin/billing/orders/#{order.uuid}/edit")

    assert number == order.order_number
    assert detail =~ "/admin/billing/orders/#{order.uuid}"

    assert %{crumbs: [%{label: "Orders"}], title: "New order"} =
             trail(conn, "/en/admin/billing/orders/new")
  end

  test "a record with no page of its own is a text crumb on its edit page", %{conn: conn} do
    {:ok, type} =
      Billing.create_subscription_type(%{
        name: "Pro",
        slug: "pro-#{System.unique_integer([:positive])}",
        price: Decimal.new("29.99")
      })

    assert %{
             crumbs: [%{label: "Subscription Types", path: _}, %{label: "Pro"} = record],
             title: "Edit"
           } =
             trail(conn, "/en/admin/billing/subscription-types/#{type.uuid}/edit")

    refute Map.has_key?(record, :path)

    assert %{crumbs: [%{label: "Subscription Types"}], title: "New subscription type"} =
             trail(conn, "/en/admin/billing/subscription-types/new")
  end

  test "a billing profile is named by its person on the edit page", %{conn: conn, user: user} do
    {:ok, profile} =
      Billing.create_billing_profile(user, %{
        "type" => "individual",
        "first_name" => "Jane",
        "last_name" => "Roe",
        "country" => "EE"
      })

    assert %{crumbs: [%{label: "Billing Profiles"}, %{label: "Jane Roe"}], title: "Edit"} =
             trail(conn, "/en/admin/billing/profiles/#{profile.uuid}/edit")
  end

  test "a subscription is named by its type", %{conn: conn, user: user} do
    {:ok, type} =
      Billing.create_subscription_type(%{
        name: "Team",
        slug: "team-#{System.unique_integer([:positive])}",
        price: Decimal.new("99.00")
      })

    {:ok, subscription} =
      Billing.create_subscription(user.uuid, %{subscription_type_uuid: type.uuid})

    assert %{crumbs: [%{label: "Subscriptions"}], title: "Team"} =
             trail(conn, "/en/admin/billing/subscriptions/#{subscription.uuid}")

    assert %{crumbs: [%{label: "Subscriptions"}, %{label: "Team", path: detail}], title: "Edit"} =
             trail(conn, "/en/admin/billing/subscriptions/#{subscription.uuid}/edit")

    assert detail =~ "/admin/billing/subscriptions/#{subscription.uuid}"
  end

  test "the settings pages live under Settings, not under the module", %{conn: conn} do
    assert %{section: "Settings", section_path: settings, crumbs: [], title: "Billing"} =
             trail(conn, "/en/admin/settings/billing")

    assert settings =~ "/admin/settings"
    refute settings =~ "/admin/settings/billing"

    assert %{
             section: "Settings",
             crumbs: [%{label: "Billing", path: billing}],
             title: "Providers"
           } =
             trail(conn, "/en/admin/settings/billing/providers")

    assert billing =~ "/admin/settings/billing"
  end

  test "no page title carries its own trail", %{conn: conn} do
    for path <- [
          "/en/admin/billing",
          "/en/admin/billing/orders",
          "/en/admin/billing/invoices",
          "/en/admin/billing/transactions",
          "/en/admin/billing/subscriptions",
          "/en/admin/billing/subscription-types",
          "/en/admin/billing/profiles",
          "/en/admin/billing/currencies",
          "/en/admin/settings/billing",
          "/en/admin/settings/billing/providers"
        ] do
      %{title: title} = trail(conn, path)
      assert is_binary(title) and title != "", path
      refute title =~ ~r/ — | - | \/ /, "#{path} title carries a trail: #{title}"
    end
  end
end
