defmodule PhoenixKitBilling.Integration.UpdateOrderStaleTest do
  @moduledoc """
  `update_order/2` decides on the stored order, not on the struct the caller read
  earlier: a form opened before another admin cancelled, confirmed or paid the
  order must not undo that.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing

  setup do
    {:ok, order} =
      Billing.create_order(fixture_user(), %{
        "total" => Decimal.new("40.00"),
        "currency" => "EUR",
        "status" => "pending",
        "billing_snapshot" => %{"email" => "g@example.com"},
        "line_items" => [%{"name" => "Item", "total" => "40.00"}]
      })

    {:ok, order: order}
  end

  test "a stale pending struct cannot resurrect a cancelled order", %{order: stale} do
    {:ok, _} = Billing.cancel_order(stale, "changed mind")

    assert {:error, :order_not_editable} = Billing.update_order(stale, %{"status" => "confirmed"})

    stored = Billing.get_order!(stale.uuid)
    assert stored.status == "cancelled"
    assert stored.metadata["cancelled_from"] == "pending"
  end

  test "a stale struct cannot edit an order that was confirmed meanwhile", %{order: stale} do
    {:ok, _} = Billing.confirm_order(stale)

    assert {:error, :order_not_editable} =
             Billing.update_order(stale, %{"notes" => "stale edit", "status" => "pending"})

    stored = Billing.get_order!(stale.uuid)
    assert stored.status == "confirmed"
    refute stored.notes == "stale edit"
  end

  test "the status rule is applied to the stored status", %{order: stale} do
    # The stale struct says draft, the stored order is pending: draft -> confirmed
    # would be allowed from the struct, pending -> pending is a plain edit.
    {:ok, _} = Billing.update_order(stale, %{"status" => "pending"})
    draft_struct = %{stale | status: "draft"}

    assert {:ok, updated} = Billing.update_order(draft_struct, %{"status" => "confirmed"})
    assert updated.status == "confirmed"

    stale_again = %{stale | status: "pending"}

    assert {:error, :order_not_editable} =
             Billing.update_order(stale_again, %{"status" => "pending"})
  end

  test "a vanished order is reported, not raised", %{order: order} do
    {:ok, draft} =
      Billing.create_order(fixture_user(), %{
        "total" => Decimal.new("5.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "g@example.com"}
      })

    {:ok, _} = Billing.delete_order(draft)

    assert {:error, :not_found} = Billing.update_order(draft, %{"notes" => "x"})
    assert order.uuid
  end

  test "an edit keeps the associations the caller loaded", %{order: order} do
    loaded = Billing.get_order(order.uuid, preload: [:user])
    assert {:ok, updated} = Billing.update_order(loaded, %{"notes" => "hello"})
    assert updated.notes == "hello"
    assert %PhoenixKit.Users.Auth.User{} = updated.user
  end
end
