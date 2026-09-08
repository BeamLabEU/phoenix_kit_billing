defmodule PhoenixKitBilling.Schemas.TransactionTest do
  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling.Transaction

  @valid %{
    transaction_number: "TXN-1",
    amount: Decimal.new("10.00"),
    currency: "EUR",
    payment_method: "bank",
    invoice_uuid: Ecto.UUID.generate(),
    user_uuid: Ecto.UUID.generate()
  }

  describe "changeset/2" do
    test "is valid with required fields" do
      assert Transaction.changeset(%Transaction{}, @valid).valid?
    end

    test "requires transaction_number, amount, currency, invoice_uuid, user_uuid" do
      errors = errors_on(Transaction.changeset(%Transaction{}, %{}))
      assert "can't be blank" in errors.transaction_number
      assert "can't be blank" in errors.amount
      assert "can't be blank" in errors.currency
      assert "can't be blank" in errors.invoice_uuid
      assert "can't be blank" in errors.user_uuid
      # payment_method ("bank") still has a schema default, so even
      # though it's in validate_required it's never blank. currency's own
      # literal default was removed once this validation existed (§7.3,
      # Э5) — see currency_defaults_test.exs.
      refute Map.has_key?(errors, :payment_method)
    end

    test "rejects a currency code that isn't exactly 3 characters" do
      cs = Transaction.changeset(%Transaction{}, %{@valid | currency: "US"})
      assert %{currency: [_ | _]} = errors_on(cs)

      cs = Transaction.changeset(%Transaction{}, %{@valid | currency: "USDD"})
      assert %{currency: [_ | _]} = errors_on(cs)
    end

    test "amount must not equal zero" do
      cs = Transaction.changeset(%Transaction{}, %{@valid | amount: Decimal.new("0")})
      assert %{amount: [_ | _]} = errors_on(cs)
    end

    test "negative amount (refund) is valid" do
      assert Transaction.changeset(%Transaction{}, %{@valid | amount: Decimal.new("-5")}).valid?
    end

    test "rejects unknown payment_method" do
      cs = Transaction.changeset(%Transaction{}, %{@valid | payment_method: "crypto"})
      assert %{payment_method: [_ | _]} = errors_on(cs)
    end
  end

  describe "type helpers" do
    test "payment?/refund?/type/absolute_amount" do
      payment = %Transaction{amount: Decimal.new("10")}
      refund = %Transaction{amount: Decimal.new("-10")}

      assert Transaction.payment?(payment)
      assert Transaction.refund?(refund)
      assert Transaction.type(payment) == "payment"
      assert Transaction.type(refund) == "refund"
      assert Transaction.absolute_amount(refund) == Decimal.new("10")
    end

    test "payment_methods/0 lists valid methods" do
      assert "bank" in Transaction.payment_methods()
      assert "stripe" in Transaction.payment_methods()
    end
  end
end
