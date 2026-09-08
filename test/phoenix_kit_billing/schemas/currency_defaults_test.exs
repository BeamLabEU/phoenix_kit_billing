defmodule PhoenixKitBilling.Schemas.CurrencyDefaultsTest do
  @moduledoc """
  Pins §7.3 of the currency design spec: a schema-level `default: "EUR"` is
  a silent answer to a question the caller must be forced to ask.
  `Order`/`Invoice` lost the literal once their changesets validated
  `:currency` (`nil` fails loudly). `Transaction` kept it until Э5 added
  `validate_required(:currency)` + `validate_length(:currency, is: 3)` —
  removing the literal first would have traded a silent "EUR" for an
  equally silent `nil`, which is worse, not better. All three now fail
  the same way.
  """

  use ExUnit.Case, async: true
  alias PhoenixKitBilling.{Invoice, Order, Transaction}

  test "Order without currency is a loud changeset error, not a silent EUR" do
    cs =
      Order.changeset(%Order{}, %{
        total: Decimal.new("1"),
        billing_snapshot: %{"email" => "a@b.c"}
      })

    assert {"can't be blank", _} = cs.errors[:currency]
  end

  test "Invoice without currency is a loud changeset error" do
    cs = Invoice.changeset(%Invoice{}, %{total: Decimal.new("1")})
    assert {"can't be blank", _} = cs.errors[:currency]
  end

  test "Transaction without currency is a loud changeset error, not a silent EUR (§7.3, Э5)" do
    cs =
      Transaction.changeset(%Transaction{}, %{
        transaction_number: "TXN-1",
        amount: Decimal.new("10.00"),
        payment_method: "bank",
        invoice_uuid: Ecto.UUID.generate(),
        user_uuid: Ecto.UUID.generate()
      })

    assert {"can't be blank", _} = cs.errors[:currency]
    refute %Transaction{} |> Map.get(:currency)
  end
end
