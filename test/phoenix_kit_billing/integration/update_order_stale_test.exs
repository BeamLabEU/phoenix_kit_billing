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
    {:ok, _} = Billing.update_order(stale, %{"status" => "pending"})

    # The stale struct says draft, the stored order is pending. Decided on the
    # struct, "draft" is no change and passes; on the stored row, pending -> draft
    # is a step back and is refused.
    assert %Ecto.Changeset{valid?: false} =
             changeset_error(
               Billing.update_order(%{stale | status: "draft"}, %{"status" => "draft"})
             )

    assert Billing.get_order!(stale.uuid).status == "pending"

    # Decided on the struct (draft), "confirmed" would be a forward move all the
    # same; the stored row (pending) allows it too, and that is what is used.
    assert {:ok, updated} =
             Billing.update_order(%{stale | status: "draft"}, %{"status" => "confirmed"})

    assert updated.status == "confirmed"

    # A stored confirmed order is not editable, whatever the struct says.
    assert {:error, :order_not_editable} =
             Billing.update_order(%{stale | status: "pending"}, %{"status" => "pending"})
  end

  test "a vanished order is reported, not raised" do
    {:ok, draft} =
      Billing.create_order(fixture_user(), %{
        "total" => Decimal.new("5.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => "g@example.com"}
      })

    {:ok, _} = Billing.delete_order(draft)

    assert {:error, :not_found} = Billing.update_order(draft, %{"notes" => "x"})
  end

  test "an edit keeps the associations the caller loaded", %{order: order} do
    loaded = Billing.get_order(order.uuid, preload: [:user])
    assert {:ok, updated} = Billing.update_order(loaded, %{"notes" => "hello"})
    assert updated.notes == "hello"
    assert %PhoenixKit.Users.Auth.User{} = updated.user
  end

  defp changeset_error({:error, %Ecto.Changeset{} = changeset}), do: changeset
end
