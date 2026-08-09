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

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Providers.Types.ChargeResult

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(
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

    # An invoice must be ISSUED before it can take money - record_payment/3
    # refuses a draft. Transition directly rather than through
    # send_invoice/1, which also delivers mail.
    {:ok, sent} =
      invoice
      |> Ecto.Changeset.change(%{status: "sent"})
      |> RepoHelper.repo().update()

    sent
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

  test "an invoice cannot be paid more than it is owed" do
    user = user_fixture()
    invoice = invoice_fixture(user)

    {:ok, _} =
      Billing.record_payment(
        invoice,
        %{amount: Decimal.new("40.00"), payment_method: "bank"},
        nil
      )

    invoice = Billing.get_invoice(invoice.uuid)

    # The admin UI already rendered this error; the context never returned
    # it, so a mistyped amount pushed paid_amount past total and flipped
    # the invoice to "paid" holding more money than it billed.
    assert {:error, :exceeds_remaining} =
             Billing.record_payment(
               invoice,
               %{amount: Decimal.new("100.00"), payment_method: "bank"},
               nil
             )

    # Exactly the remaining balance is still accepted.
    assert {:ok, _} =
             Billing.record_payment(
               invoice,
               %{amount: Decimal.new("60.00"), payment_method: "bank"},
               nil
             )
  end

  test "marking an invoice paid settles the ledger, not just the status" do
    user = user_fixture()
    invoice = invoice_fixture(user)

    {:ok, invoice} = Billing.mark_invoice_paid(invoice)

    assert invoice.status == "paid"
    # Without this the invoice read PAID while the ledger said nothing had
    # arrived, and the receipt claimed the full total anyway.
    assert Decimal.equal?(invoice.paid_amount, invoice.total)
    assert Decimal.equal?(PhoenixKitBilling.Invoice.remaining_amount(invoice), Decimal.new("0"))
  end

  test "two overlapping payment attempts cannot together exceed the balance" do
    user = user_fixture()
    invoice = invoice_fixture(user)

    # The caller's cap reads `remaining` from an invoice fetched BEFORE the
    # transaction, so two attempts holding the same stale invoice both saw
    # the full balance. The in-transaction re-check on the locked row is
    # what rejects the second.
    #
    # ⚠️ This pins the OUTCOME, not true parallelism: the sandbox shares one
    # connection, so the two tasks serialize rather than racing. The
    # SELECT ... FOR UPDATE it exercises is what makes the real concurrent
    # case safe; proving that needs a non-sandboxed database.
    task = fn ->
      Task.async(fn ->
        PhoenixKitBilling.DataCase.allow_sandbox(self())

        Billing.record_payment(
          Billing.get_invoice(invoice.uuid),
          %{amount: Decimal.new("100.00"), payment_method: "bank"},
          nil
        )
      end)
    end

    results = [task.(), task.()] |> Enum.map(&Task.await(&1, 15_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :exceeds_remaining}, &1)) == 1

    assert Decimal.equal?(Billing.get_invoice(invoice.uuid).paid_amount, Decimal.new("100.00"))
  end

  test "marking paid writes a ledger row, so the invoice can still be refunded" do
    user = user_fixture()
    invoice = invoice_fixture(user)

    {:ok, invoice} = Billing.mark_invoice_paid(invoice)

    # Without a transaction, a later refund recalculates paid_amount from
    # transactions summing to -60 and the update is rolled back: an invoice
    # the system says was paid that nobody can refund.
    assert {:ok, _refund} =
             Billing.record_refund(
               invoice,
               %{amount: Decimal.new("60.00"), description: "partial"},
               nil
             )

    refreshed = Billing.get_invoice(invoice.uuid)
    assert Decimal.equal?(refreshed.paid_amount, Decimal.new("40.00"))
  end

  test "money cannot be recorded against an invoice that was never issued" do
    user = user_fixture()

    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "billing_snapshot" => %{"email" => user.email}
      })

    {:ok, draft} = Billing.create_invoice_from_order(order)
    assert draft.status == "draft"

    assert {:error, :not_payable} =
             Billing.record_payment(
               draft,
               %{amount: Decimal.new("10.00"), payment_method: "bank"},
               nil
             )
  end

  test "a provider's result STRUCT can be recorded as provider_data" do
    user = user_fixture()
    invoice = invoice_fixture(user)

    # Exactly what SubscriptionRenewalWorker passes: the provider's own
    # `%ChargeResult{}`. `provider_data` is a `:map` column and Ecto passes a
    # struct through both cast and dump untouched, so the failure landed in
    # the JSON encoder as a RAISE from inside the repo transaction - after
    # the card had been charged. Oban then retried the renewal, invoicing
    # and charging the customer again.
    charge = %ChargeResult{
      id: "ch_struct",
      provider_transaction_id: "ch_struct",
      amount: Decimal.new("100.00"),
      currency: "EUR",
      status: "succeeded",
      metadata: %{nested: %{"deep" => :atom_value}}
    }

    assert {:ok, transaction} =
             Billing.record_payment(
               invoice,
               %{
                 amount: Decimal.new("100.00"),
                 payment_method: "stripe",
                 provider_transaction_id: charge.provider_transaction_id,
                 provider_data: charge
               },
               nil
             )

    # Stored as a plain map, and readable back out of Postgres.
    stored = Billing.get_transaction!(transaction.uuid).provider_data
    refute is_struct(stored)
    assert stored["status"] == "succeeded"
    assert stored["provider_transaction_id"] == "ch_struct"
    assert Decimal.equal?(Billing.get_invoice(invoice.uuid).paid_amount, Decimal.new("100.00"))
  end

  test "marking paid keeps the status and the ledger row in one transaction" do
    user = user_fixture()
    invoice = invoice_fixture(user)

    {:ok, paid} = Billing.mark_invoice_paid(invoice)

    assert paid.status == "paid"
    assert Decimal.equal?(paid.paid_amount, Decimal.new("100.00"))

    # The settlement row exists and covers the whole balance: status and
    # ledger agree. A discarded insert error would leave these disagreeing.
    ledger =
      [invoice_uuid: invoice.uuid]
      |> Billing.list_transactions()
      |> Enum.reduce(Decimal.new("0"), &Decimal.add(&2, &1.amount))

    assert Decimal.equal?(ledger, Decimal.new("100.00"))
  end
end
