defmodule PhoenixKitBilling.Web.SubscriptionPricingLvsTest do
  @moduledoc """
  What the admin pages say about what a subscription pays, and the refusal an
  operator meets on an order with an open invoice.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Subscription}
  alias PhoenixKitBilling.Test.Repo

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)

    {:ok, conn: put_test_scope(conn, scope), user: user}
  end

  defp plan(attrs \\ %{}) do
    {:ok, type} =
      %{
        name: "Plan",
        slug: "plan-#{System.unique_integer([:positive])}",
        price: Decimal.new("5.00"),
        currency: "EUR"
      }
      |> Map.merge(attrs)
      |> Billing.create_subscription_type()

    type
  end

  defp subscribed(user, type) do
    {:ok, subscription} =
      Billing.create_subscription(user.uuid, %{subscription_type_uuid: type.uuid, trial_days: 14})

    subscription
  end

  defp confirmed_order(user) do
    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("99.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "g@example.com"},
        "line_items" => [%{"name" => "Item", "total" => "99.00"}]
      })

    {:ok, confirmed} = Billing.confirm_order(order)
    confirmed
  end

  describe "the price a subscriber sees" do
    setup %{user: user} do
      type = plan()
      subscription = subscribed(user, type)
      {:ok, type} = Billing.update_subscription_type(type, %{price: Decimal.new("9.00")})

      {:ok, type: type, subscription: subscription}
    end

    test "the detail page shows what the subscription pays, not the plan's price", %{
      conn: conn,
      subscription: subscription
    } do
      {:ok, _view, html} = live(conn, "/en/admin/billing/subscriptions/#{subscription.uuid}")

      assert html =~ "5.00"
      refute html =~ "9.00"
    end

    test "the list shows what the subscription pays, not the plan's price", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/billing/subscriptions")

      assert html =~ "5.00"
      refute html =~ "9.00"
    end
  end

  describe "applying a plan's price to its subscribers" do
    setup %{user: user} do
      type = plan()
      subscription = subscribed(user, type)
      {:ok, type} = Billing.update_subscription_type(type, %{price: Decimal.new("9.00")})

      {:ok, type: type, subscription: subscription}
    end

    test "moves them and says how many", %{conn: conn, type: type, subscription: subscription} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/subscription-types")

      html = render_click(view, "apply_plan_price", %{"uuid" => type.uuid})

      assert html =~ "Subscriptions moved to the current price: 1"
      assert Decimal.equal?(Repo.get!(Subscription, subscription.uuid).price, "9.00")

      assert_activity_logged("billing.subscription_type_price_applied",
        resource_uuid: type.uuid,
        metadata_has: %{"count" => 1, "currency" => "EUR"}
      )
    end

    test "needs manage_subscriptions", %{conn: conn, type: type, subscription: subscription} do
      conn = put_test_scope(conn, fake_scope(roles: ["Employee"], permissions: ["billing"]))
      {:ok, view, _html} = live(conn, "/en/admin/billing/subscription-types")

      render_click(view, "apply_plan_price", %{"uuid" => type.uuid})

      assert Decimal.equal?(Repo.get!(Subscription, subscription.uuid).price, "5.00")
    end
  end

  describe "marking an order paid with an invoice open" do
    test "points the operator at the invoice", %{conn: conn, user: user} do
      order = confirmed_order(user)
      {:ok, invoice} = Billing.create_invoice_from_order(order)
      {:ok, _} = invoice |> Invoice.status_changeset("sent") |> Repo.update()

      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}")

      html = render_click(view, "mark_paid", %{})

      assert html =~ "Mark that invoice as paid"
      assert Billing.get_order!(order.uuid).status == "confirmed"
    end
  end

  describe "the new subscription form" do
    defp pick_plan(view, type) do
      view
      |> element(~s|form[phx-change="select_subscription_type"]|)
      |> render_change(%{"subscription_type_uuid" => type.uuid})
    end

    test "says a plan without a trial is charged now", %{conn: conn} do
      type = plan()
      {:ok, view, _html} = live(conn, "/en/admin/billing/subscriptions/new")

      assert pick_plan(view, type) =~ "The first period is charged when you create"
    end

    test "says a trial is charged when it ends", %{conn: conn} do
      type = plan(%{trial_days: 14})
      {:ok, view, _html} = live(conn, "/en/admin/billing/subscriptions/new")

      html = pick_plan(view, type)

      assert html =~ "The first charge comes when the trial ends"
      refute html =~ "The first period is charged when you create"
    end

    test "says a trial of no days is charged now, because the save would", %{conn: conn} do
      type = plan()
      {:ok, view, _html} = live(conn, "/en/admin/billing/subscriptions/new")
      pick_plan(view, type)

      assert render_click(view, "toggle_trial", %{"enable" => "true"}) =~
               "The first period is charged when you create"

      assert render_click(view, "update_trial_days", %{"days" => "0"}) =~
               "The first period is charged when you create"

      assert render_click(view, "update_trial_days", %{"days" => "7"}) =~
               "The first charge comes when the trial ends"
    end

    test "disables the button while it saves: a second click would charge again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/subscriptions/new")

      assert has_element?(view, "#create-subscription-button[phx-disable-with]")
    end

    test "says nothing about a charge on a free plan", %{conn: conn} do
      type = plan(%{name: "Free", price: Decimal.new("0")})
      {:ok, view, _html} = live(conn, "/en/admin/billing/subscriptions/new")

      html = pick_plan(view, type)

      assert html =~ "Free"
      refute html =~ "The first period is charged when you create"
    end
  end

  describe "the order form" do
    test "opens for a Finnish billing profile, whose VAT rate has a fraction", %{
      conn: conn,
      user: user
    } do
      {:ok, profile} =
        Billing.create_billing_profile(user, %{
          "type" => "individual",
          "first_name" => "Jane",
          "last_name" => "Roe",
          "country" => "FI"
        })

      {:ok, order} =
        Billing.create_order(user, %{
          "total" => Decimal.new("99.00"),
          "currency" => "EUR",
          "billing_profile_uuid" => profile.uuid,
          "billing_snapshot" => %{"email" => "g@example.com"},
          "line_items" => [%{"name" => "Item", "total" => "99.00"}]
        })

      assert {:ok, _view, _html} = live(conn, "/en/admin/billing/orders/#{order.uuid}/edit")
    end
  end
end
