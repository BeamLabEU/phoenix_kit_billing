defmodule PhoenixKitBilling.Schemas.OrderTest do
  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling.Order

  # Minimum valid: guest order needs a billing_snapshot with an email.
  @valid %{
    total: Decimal.new("99.00"),
    currency: "EUR",
    billing_snapshot: %{"email" => "guest@example.com"}
  }

  describe "changeset/2" do
    test "is valid for a guest order with billing snapshot email" do
      assert Order.changeset(%Order{}, @valid).valid?
    end

    test "requires total AND currency (no schema default answers for the caller)" do
      cs = Order.changeset(%Order{}, %{billing_snapshot: %{"email" => "g@e.com"}})
      errors = errors_on(cs)
      assert "can't be blank" in errors.total
      # The schema default was removed (§7.3): a missing currency is a loud
      # changeset error, not a silent "EUR".
      assert "can't be blank" in errors.currency
    end

    test "guest order without billing profile or snapshot email is invalid" do
      cs = Order.changeset(%Order{}, %{total: Decimal.new("10"), currency: "EUR"})
      assert %{billing_snapshot: ["must have email for guest orders"]} = errors_on(cs)
    end

    test "currency must be 3 chars" do
      cs = Order.changeset(%Order{}, %{@valid | currency: "EU"})
      assert %{currency: [_ | _]} = errors_on(cs)
    end

    test "rejects invalid status" do
      cs = Order.changeset(%Order{}, Map.put(@valid, :status, "bogus"))
      assert %{status: [_ | _]} = errors_on(cs)
    end

    test "rejects invalid payment_method but allows nil" do
      assert Order.changeset(%Order{}, Map.put(@valid, :payment_method, nil)).valid?

      cs = Order.changeset(%Order{}, Map.put(@valid, :payment_method, "bitcoin"))
      assert %{payment_method: [_ | _]} = errors_on(cs)

      assert Order.changeset(%Order{}, Map.put(@valid, :payment_method, "stripe")).valid?
    end

    test "negative total is invalid" do
      cs = Order.changeset(%Order{}, %{@valid | total: Decimal.new("-1")})
      assert %{total: [_ | _]} = errors_on(cs)
    end

    test "line_items missing name is invalid" do
      cs = Order.changeset(%Order{}, Map.put(@valid, :line_items, [%{"quantity" => 1}]))
      assert %{line_items: [_ | _]} = errors_on(cs)
    end

    test "line_items with name is valid" do
      attrs = Map.put(@valid, :line_items, [%{"name" => "Item", "total" => "99.00"}])
      assert Order.changeset(%Order{}, attrs).valid?
    end
  end

  describe "status_changeset/2 transitions" do
    test "draft -> confirmed sets confirmed_at" do
      cs = Order.status_changeset(%Order{status: "draft"}, "confirmed")
      assert cs.valid?
      assert get_change(cs, :confirmed_at)
    end

    test "draft -> paid is rejected" do
      cs = Order.status_changeset(%Order{status: "draft"}, "paid")
      refute cs.valid?
      assert %{status: [_ | _]} = errors_on(cs)
    end

    test "paid -> refunded is allowed" do
      assert Order.status_changeset(%Order{status: "paid"}, "refunded").valid?
    end

    test "cancelled is terminal" do
      cs = Order.status_changeset(%Order{status: "cancelled"}, "paid")
      refute cs.valid?
    end
  end

  describe "calculate_totals/3" do
    test "sums line items, applies tax on (subtotal - discount)" do
      items = [%{"total" => "100.00"}, %{"total" => "50.00"}]
      {subtotal, tax, total} = Order.calculate_totals(items, Decimal.new("0.20"))
      assert Decimal.equal?(subtotal, Decimal.new("150.00"))
      assert Decimal.equal?(tax, Decimal.new("30.00"))
      assert Decimal.equal?(total, Decimal.new("180.00"))
    end
  end

  describe "predicates" do
    test "editable?/1" do
      assert Order.editable?(%Order{status: "draft"})
      assert Order.editable?(%Order{status: "pending"})
      refute Order.editable?(%Order{status: "paid"})
    end

    test "payable?/1 only for confirmed" do
      assert Order.payable?(%Order{status: "confirmed"})
      refute Order.payable?(%Order{status: "draft"})
    end

    test "status_label/1 and status_color/1" do
      assert Order.status_label("paid") == "Paid"
      assert Order.status_label("???") == "Unknown"
      assert Order.status_color("paid") == "badge-success"
      assert Order.status_color("???") == "badge-ghost"
    end
  end
end
