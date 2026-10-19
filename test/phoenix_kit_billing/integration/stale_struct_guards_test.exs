defmodule PhoenixKitBilling.Integration.StaleStructGuardsTest do
  @moduledoc """
  Order status transitions and invoice refunds must be validated against the
  stored row, not against the struct the caller read earlier.

  Each test reads a struct, changes the row through another path (a second
  caller, in production) and then calls the context with the stale struct.
  """

  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Order

  describe "order transitions with a stale struct" do
    setup do
      {:ok, user: fixture_user()}
    end

    test "confirm_order/1 does not overwrite a cancelled order", %{user: user} do
      {:ok, stale} = create_order(user)
      {:ok, _cancelled} = Billing.cancel_order(Billing.get_order!(stale.uuid))

      assert {:error, %Ecto.Changeset{} = changeset} = Billing.confirm_order(stale)
      assert %{status: [_ | _]} = errors_on(changeset)

      stored = Billing.get_order!(stale.uuid)
      assert stored.status == "cancelled"
      assert stored.confirmed_at == nil
    end

    test "mark_order_paid/2 does not pay a cancelled order", %{user: user} do
      {:ok, order} = create_order(user)
      {:ok, stale} = Billing.confirm_order(order)
      {:ok, _cancelled} = Billing.cancel_order(Billing.get_order!(stale.uuid))

      assert {:error, :order_not_payable} = Billing.mark_order_paid(stale, payment_method: "bank")

      stored = Billing.get_order!(stale.uuid)
      assert stored.status == "cancelled"
      assert stored.paid_at == nil
      assert stored.payment_method == nil
    end

    test "cancel_order/2 does not cancel a paid order", %{user: user} do
      {:ok, order} = create_order(user)
      {:ok, stale} = Billing.confirm_order(order)
      {:ok, _paid} = Billing.mark_order_paid(Billing.get_order!(stale.uuid))

      assert {:error, :order_not_cancellable} = Billing.cancel_order(stale, "too late")

      stored = Billing.get_order!(stale.uuid)
      assert stored.status == "paid"
      assert stored.paid_at != nil
      assert stored.cancelled_at == nil
      assert stored.internal_notes == nil
    end

    test "mark_order_refunded/1 does not refund twice", %{user: user} do
      {:ok, order} = create_order(user)
      {:ok, confirmed} = Billing.confirm_order(order)
      {:ok, stale} = Billing.mark_order_paid(confirmed)
      {:ok, refunded} = Billing.mark_order_refunded(Billing.get_order!(stale.uuid))

      assert {:error, :order_not_refundable} = Billing.mark_order_refunded(stale)

      stored = Billing.get_order!(stale.uuid)
      assert stored.status == "refunded"
      assert stored.updated_at == refunded.updated_at
    end

    test "a paid and a cancelled writer holding the same order never end as cancelled with paid_at",
         %{user: user} do
      {:ok, order} = create_order(user)
      {:ok, confirmed} = Billing.confirm_order(order)

      # Two callers read the same confirmed order. Whoever writes first wins;
      # the other must be refused instead of overwriting it.
      reader_a = Billing.get_order!(confirmed.uuid)
      reader_b = Billing.get_order!(confirmed.uuid)

      assert {:ok, %Order{status: "paid"}} = Billing.mark_order_paid(reader_a)
      assert {:error, :order_not_cancellable} = Billing.cancel_order(reader_b)

      stored = Billing.get_order!(confirmed.uuid)
      assert stored.status == "paid"
      assert stored.paid_at != nil
      assert stored.cancelled_at == nil
    end

    test "the reverse order: cancelled first, the stale payment is refused", %{user: user} do
      {:ok, order} = create_order(user)
      {:ok, confirmed} = Billing.confirm_order(order)

      reader_a = Billing.get_order!(confirmed.uuid)
      reader_b = Billing.get_order!(confirmed.uuid)

      assert {:ok, %Order{status: "cancelled"}} = Billing.cancel_order(reader_b)
      assert {:error, :order_not_payable} = Billing.mark_order_paid(reader_a)

      stored = Billing.get_order!(confirmed.uuid)
      assert stored.status == "cancelled"
      assert stored.cancelled_at != nil
      assert stored.paid_at == nil
    end

    test "the returned order keeps the caller's preloads", %{user: user} do
      {:ok, order} = create_order(user)
      preloaded = Billing.get_order!(order.uuid)
      assert Ecto.assoc_loaded?(preloaded.billing_profile)

      assert {:ok, confirmed} = Billing.confirm_order(preloaded)
      assert Ecto.assoc_loaded?(confirmed.billing_profile)
    end
  end

  describe "refund with a stale invoice" do
    setup do
      user = fixture_user()

      {:ok, invoice} =
        Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

      {:ok, invoice, _email_result} =
        Billing.send_invoice(invoice, to_email: "customer@example.com", send_email: false)

      {:ok, _payment} = Billing.record_payment(invoice, %{amount: "100.00"}, nil)

      {:ok, invoice: Billing.get_invoice!(invoice.uuid)}
    end

    test "a second refund beyond the paid amount is an error, not an exception",
         %{invoice: invoice} do
      # Both callers saw paid_amount = 100 and each asks for 60.
      stale = invoice

      assert {:ok, _refund} = Billing.record_refund(invoice, refund_attrs("60.00"), nil)

      assert {:error, :exceeds_paid_amount} =
               Billing.record_refund(stale, refund_attrs("60.00"), nil)

      reloaded = Billing.get_invoice!(invoice.uuid)
      assert Decimal.equal?(reloaded.paid_amount, Decimal.new("40.00"))
      assert refund_count(invoice.uuid) == 1
    end

    test "a second refund for exactly the remaining paid amount still succeeds",
         %{invoice: invoice} do
      stale = invoice

      assert {:ok, _refund} = Billing.record_refund(invoice, refund_attrs("60.00"), nil)
      assert {:ok, _refund} = Billing.record_refund(stale, refund_attrs("40.00"), nil)

      reloaded = Billing.get_invoice!(invoice.uuid)
      assert Decimal.equal?(reloaded.paid_amount, Decimal.new("0"))
      assert refund_count(invoice.uuid) == 2
    end

    test "the caller's own bound still applies to a fresh invoice", %{invoice: invoice} do
      assert {:error, :exceeds_paid_amount} =
               Billing.record_refund(invoice, refund_attrs("100.01"), nil)

      assert {:error, :invalid_amount} = Billing.record_refund(invoice, refund_attrs("0"), nil)
    end
  end

  defp create_order(user) do
    Billing.create_order(user, %{
      "total" => Decimal.new("99.00"),
      "currency" => "EUR",
      "billing_snapshot" => %{"email" => "g@example.com"},
      "line_items" => [%{"name" => "Item", "total" => "99.00"}]
    })
  end

  defp refund_attrs(amount), do: %{amount: amount, description: "refund #{amount}"}

  defp refund_count(invoice_uuid) do
    invoice_uuid
    |> Billing.list_invoice_transactions()
    |> Enum.count(&Decimal.negative?(&1.amount))
  end
end
