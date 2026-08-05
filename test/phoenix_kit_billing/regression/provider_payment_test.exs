defmodule PhoenixKitBilling.Regression.ProviderPaymentTest do
  @moduledoc """
  Provider-driven payments (webhooks, the renewal worker) carry NO admin
  actor. `Transaction` requires `user_uuid`, so every one of them failed to
  insert: the customer was charged at the provider, the invoice stayed
  unpaid with `paid_amount` 0, and there was no ledger row to reconcile
  against. The provider's own charge id was dropped too, so a later refund
  webhook could not be matched to the charge it reverses.

  These pin the attribution and the carried provider fields.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling, as: Billing

  defp user_fixture do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(
        %{
          email: "payer-#{System.unique_integer([:positive])}@example.com",
          password: "hello world!123"
        },
        nil
      )

    user
  end

  defp invoice_fixture(user) do
    {:ok, order} =
      Billing.create_order(user, %{
        "line_items" => [
          %{"name" => "Item", "quantity" => 1, "unit_price" => "100.00", "total" => "100.00"}
        ],
        "subtotal" => Decimal.new("100.00"),
        "total" => Decimal.new("100.00"),
        "currency" => "EUR",
        "status" => "pending",
        "billing_snapshot" => %{"email" => user.email}
      })

    {:ok, invoice} = Billing.create_invoice_from_order(order)
    invoice
  end

  test "a payment with no admin actor is attributed to the invoice's user" do
    user = user_fixture()
    invoice = invoice_fixture(user)

    # Exactly what the webhook processor and the renewal worker pass: no
    # scope at all.
    assert {:ok, transaction} =
             Billing.record_payment(
               invoice,
               %{
                 amount: Decimal.new("100.00"),
                 payment_method: "stripe",
                 provider_transaction_id: "ch_test_123",
                 provider_data: %{"raw" => "payload"}
               },
               nil
             )

    assert transaction.user_uuid == user.uuid
    # ...and the invoice actually records the money.
    assert Decimal.equal?(Billing.get_invoice(invoice.uuid).paid_amount, Decimal.new("100.00"))
  end

  test "the provider's charge id is carried onto the transaction" do
    user = user_fixture()
    invoice = invoice_fixture(user)

    {:ok, transaction} =
      Billing.record_payment(
        invoice,
        %{
          amount: Decimal.new("50.00"),
          payment_method: "stripe",
          provider_transaction_id: "ch_carry_me",
          provider_data: %{"object" => "charge"}
        },
        nil
      )

    # Without this a refund webhook cannot find the charge it reverses, so
    # the books keep showing the full paid amount after a provider refund.
    assert transaction.provider_transaction_id == "ch_carry_me"
    assert transaction.provider_data["object"] == "charge"
  end

  test "an admin-recorded payment is still attributed to the admin" do
    user = user_fixture()
    admin = user_fixture()
    invoice = invoice_fixture(user)

    {:ok, transaction} =
      Billing.record_payment(
        invoice,
        %{amount: Decimal.new("10.00"), payment_method: "bank"},
        %{user: %{uuid: admin.uuid}}
      )

    assert transaction.user_uuid == admin.uuid
  end
end
