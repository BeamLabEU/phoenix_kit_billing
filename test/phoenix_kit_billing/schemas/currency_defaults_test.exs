defmodule PhoenixKitBilling.Schemas.CurrencyDefaultsTest do
  @moduledoc """
  Pins §7.3 of the currency design spec: a schema-level `default: "EUR"` is
  a silent answer to a question the caller must be forced to ask.
  `Order`/`Invoice` lose the literal (their changesets already validate
  `:currency`, so `nil` now fails loudly); `Transaction` keeps it until it
  gets the same validation (Э5) — removing it first would trade a silent
  "EUR" for an equally silent `nil`, which is worse, not better.
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

  test "Transaction keeps its schema default until it gets validation (§7.3, Э5)" do
    assert %Transaction{currency: "EUR"} = %Transaction{}
  end
end
