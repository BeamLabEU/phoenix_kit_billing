defmodule PhoenixKitBilling.Web.UserOrdersTest do
  @moduledoc """
  Regression tests for the customer-facing "My Orders" LiveView
  (`/dashboard/billing-orders`).

  `Billing.list_user_orders/3`'s new `:preload` option is what makes this
  page work at all — the association is unloaded by default, and the
  template reads `order.invoices` and `invoice.transactions` for every
  order it renders. Test 1 below doubles as the regression guard for that:
  it was confirmed red (an `Ecto.Association.NotLoaded` render crash)
  against a version of `UserOrders.mount/3` that dropped the `preload:`
  option, then green again once restored — see the implementer's report
  for the pasted red/green output.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, user: user}
  end

  defp fixture_order_chain(user) do
    {:ok, order} =
      Billing.create_order(user.uuid, %{
        "total" => Decimal.new("100.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => user.email}
      })

    {:ok, invoice} = Billing.create_invoice_from_order(order)

    {:ok, invoice} =
      Billing.send_invoice(invoice, to_email: user.email, send_email: false)

    {:ok, _payment} = Billing.record_payment(invoice, %{amount: "60.00"}, nil)
    paid_invoice = Billing.get_invoice!(invoice.uuid)
    {:ok, _refund} = Billing.record_refund(paid_invoice, %{amount: "10.00"}, nil)

    order
  end

  describe "UserOrders" do
    test "renders the current user's own orders, invoices, and transactions", %{
      conn: conn,
      user: user
    } do
      order = fixture_order_chain(user)
      invoice = Billing.get_order(order.uuid, preload: [:invoices]).invoices |> hd()

      {:ok, _view, html} = live(conn, "/en/dashboard/billing-orders")

      assert html =~ order.order_number
      assert html =~ invoice.invoice_number
      assert html =~ "Payment"
      assert html =~ "Refund"
    end

    test "never shows another user's orders", %{conn: conn, user: user} do
      order = fixture_order_chain(user)

      other_user = fixture_user()

      {:ok, other_order} =
        Billing.create_order(other_user.uuid, %{
          "total" => Decimal.new("50.00"),
          "currency" => "EUR",
          "billing_snapshot" => %{"email" => other_user.email}
        })

      {:ok, _view, html} = live(conn, "/en/dashboard/billing-orders")

      assert html =~ order.order_number
      refute html =~ other_order.order_number
    end
  end
end
