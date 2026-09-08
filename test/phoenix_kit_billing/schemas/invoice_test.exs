defmodule PhoenixKitBilling.Schemas.InvoiceTest do
  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Order

  @valid %{user_uuid: Ecto.UUID.generate(), total: Decimal.new("50.00"), currency: "EUR"}

  describe "changeset/2" do
    test "is valid with required fields" do
      assert Invoice.changeset(%Invoice{}, @valid).valid?
    end

    test "requires user_uuid, total AND currency (no schema default)" do
      errors = errors_on(Invoice.changeset(%Invoice{}, %{}))
      assert "can't be blank" in errors.user_uuid
      assert "can't be blank" in errors.total
      # The schema default was removed (§7.3): a missing currency is a loud
      # changeset error, not a silent "EUR".
      assert "can't be blank" in errors.currency
    end

    test "rejects invalid status" do
      cs = Invoice.changeset(%Invoice{}, Map.put(@valid, :status, "bogus"))
      assert %{status: [_ | _]} = errors_on(cs)
    end

    test "currency must be 3 chars" do
      cs = Invoice.changeset(%Invoice{}, %{@valid | currency: "EURO"})
      assert %{currency: [_ | _]} = errors_on(cs)
    end

    test "negative total / paid_amount are invalid" do
      assert %{total: [_ | _]} =
               errors_on(Invoice.changeset(%Invoice{}, %{@valid | total: Decimal.new("-1")}))

      assert %{paid_amount: [_ | _]} =
               errors_on(
                 Invoice.changeset(%Invoice{}, Map.put(@valid, :paid_amount, Decimal.new("-1")))
               )
    end

    test "line item without name is invalid" do
      cs =
        Invoice.changeset(
          %Invoice{},
          Map.put(@valid, :line_items, [%{"quantity" => 1, "total" => "5"}])
        )

      assert %{line_items: [_ | _]} = errors_on(cs)
    end

    test "line item with non-positive quantity is invalid" do
      cs =
        Invoice.changeset(
          %Invoice{},
          Map.put(@valid, :line_items, [%{"name" => "X", "quantity" => 0, "total" => "5"}])
        )

      assert %{line_items: [_ | _]} = errors_on(cs)
    end

    test "valid line item passes" do
      attrs = Map.put(@valid, :line_items, [%{"name" => "X", "quantity" => 1, "total" => "5"}])
      assert Invoice.changeset(%Invoice{}, attrs).valid?
    end
  end

  describe "status_changeset/2" do
    test "draft -> sent sets sent_at" do
      cs = Invoice.status_changeset(%Invoice{status: "draft"}, "sent")
      assert cs.valid?
      assert get_change(cs, :sent_at)
    end

    test "draft -> paid is rejected" do
      refute Invoice.status_changeset(%Invoice{status: "draft"}, "paid").valid?
    end

    test "sent -> paid allowed; void is terminal" do
      assert Invoice.status_changeset(%Invoice{status: "sent"}, "paid").valid?
      refute Invoice.status_changeset(%Invoice{status: "void"}, "paid").valid?
    end
  end

  describe "from_order/2" do
    test "copies order financials and sets due date" do
      order = %Order{
        uuid: Ecto.UUID.generate(),
        user_uuid: Ecto.UUID.generate(),
        subtotal: Decimal.new("100"),
        tax_amount: Decimal.new("20"),
        tax_rate: Decimal.new("0.20"),
        total: Decimal.new("120"),
        currency: "EUR",
        line_items: [%{"name" => "X", "total" => "100"}],
        billing_snapshot: %{"email" => "a@b.com"}
      }

      inv = Invoice.from_order(order, due_days: 7)
      assert inv.total == Decimal.new("120")
      assert inv.order_uuid == order.uuid
      assert inv.due_date == Date.add(Date.utc_today(), 7)
      assert inv.billing_details == %{"email" => "a@b.com"}
    end
  end

  describe "predicates" do
    test "remaining_amount/1 and fully_paid?/1" do
      inv = %Invoice{total: Decimal.new("100"), paid_amount: Decimal.new("40")}
      assert Invoice.remaining_amount(inv) == Decimal.new("60")
      refute Invoice.fully_paid?(inv)
      assert Invoice.fully_paid?(%{inv | paid_amount: Decimal.new("100")})
    end

    test "overdue?/1" do
      refute Invoice.overdue?(%Invoice{status: "paid", due_date: ~D[2000-01-01]})
      assert Invoice.overdue?(%Invoice{status: "sent", due_date: ~D[2000-01-01]})
      refute Invoice.overdue?(%Invoice{status: "sent", due_date: nil})
    end

    test "payment_methods/1 dedupes across transactions" do
      txns = [
        %PhoenixKitBilling.Transaction{payment_method: "bank", amount: Decimal.new("10")},
        %PhoenixKitBilling.Transaction{payment_method: "bank", amount: Decimal.new("10")},
        %PhoenixKitBilling.Transaction{payment_method: "stripe", amount: Decimal.new("5")}
      ]

      assert Invoice.payment_methods(%Invoice{transactions: txns}) == ["bank", "stripe"]
      assert Invoice.payment_methods(%Invoice{transactions: []}) == []
    end
  end
end
