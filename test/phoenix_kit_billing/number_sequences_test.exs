defmodule PhoenixKitBilling.NumberSequencesTest do
  @moduledoc """
  Order, invoice and receipt numbers come from a counter taken in the same
  transaction as the insert that uses the number. They used to be
  `count(rows of the year) + 1`, so deleting any row but the last handed out a
  number already taken - the insert failed on the unique index, and kept
  failing, which blocked every new order or invoice of the year.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Events
  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Order
  alias PhoenixKitBilling.Transaction

  @sequences "phoenix_kit_billing_number_sequences"
  @year Date.utc_today().year

  setup do
    # Rolled back with the test's sandbox transaction.
    Repo.delete_all(from(s in @sequences))
    %{user: fixture_user()}
  end

  defp number(prefix, n, year \\ @year),
    do: "#{prefix}-#{year}-#{String.pad_leading(to_string(n), 4, "0")}"

  defp last_value(scope, year \\ @year) do
    Repo.one(
      from(s in @sequences, where: s.scope == ^scope and s.year == ^year, select: s.last_value)
    )
  end

  defp order_attrs(extra \\ %{}) do
    Map.merge(
      %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "status" => "pending",
        "billing_snapshot" => %{"email" => "buyer@example.com"}
      },
      extra
    )
  end

  defp new_order(user, extra \\ %{}) do
    {:ok, order} = Billing.create_order(user, order_attrs(extra))
    order
  end

  # A plain insert: gives a row a number without touching the counter.
  defp insert_order(user, order_number, extra \\ []) do
    {:ok, order} = Billing.create_order(user, order_attrs(%{"order_number" => order_number}))

    if extra != [],
      do: Repo.update_all(from(o in Order, where: o.uuid == ^order.uuid), set: extra)

    order
  end

  defp new_invoice(order) do
    {:ok, invoice} = Billing.create_invoice_from_order(order)
    invoice
  end

  # A paid invoice has ledger rows pointing at it.
  defp delete_invoice(invoice) do
    Repo.delete_all(from(t in Transaction, where: t.invoice_uuid == ^invoice.uuid))
    Repo.delete!(invoice)
  end

  defp sent(invoice) do
    {:ok, sent} = invoice |> Ecto.Changeset.change(%{status: "sent"}) |> Repo.update()
    sent
  end

  describe "orders" do
    test "numbers run on from 0001", %{user: user} do
      assert new_order(user).order_number == number("ORD", 1)
      assert new_order(user).order_number == number("ORD", 2)
      assert last_value("order") == 2
    end

    test "deleting an order of the year does not free its number", %{user: user} do
      [_first, second, third] = for _ <- 1..3, do: new_order(user, %{"status" => "draft"})

      {:ok, _} = Billing.delete_order(second)
      assert new_order(user).order_number == number("ORD", 4)

      {:ok, _} = Billing.delete_order(third)
      assert new_order(user).order_number == number("ORD", 5)
    end

    test "create_order/1 takes its number from the same counter", %{user: user} do
      assert new_order(user).order_number == number("ORD", 1)

      assert {:ok, order} = Billing.create_order(order_attrs(%{"user_uuid" => user.uuid}))
      assert order.order_number == number("ORD", 2)
    end

    test "an insert that fails its changeset gives its number back", %{user: user} do
      assert new_order(user).order_number == number("ORD", 1)

      assert {:error, %Ecto.Changeset{}} =
               Billing.create_order(user, order_attrs(%{"total" => Decimal.new("-1")}))

      assert last_value("order") == 1
      assert new_order(user).order_number == number("ORD", 2)
    end

    test "a failed order announces nothing, a created one does", %{user: user} do
      Events.subscribe_orders()

      assert {:error, _} =
               Billing.create_order(user, order_attrs(%{"total" => Decimal.new("-1")}))

      refute_receive {:order_created, _}

      order = new_order(user)
      assert_receive {:order_created, ^order}
    end

    test "a counter-less year starts after the numbers already there", %{user: user} do
      # Fewer rows than the highest number: the count alone would hand out
      # 0003, which is taken.
      insert_order(user, number("ORD", 3))
      insert_order(user, number("ORD", 10))
      assert last_value("order") == nil

      assert new_order(user).order_number == number("ORD", 11)
      assert last_value("order") == 11
    end

    test "a counter-less year also counts rows whose number is not in the format", %{user: user} do
      for n <- ["A", "B", "C"], do: insert_order(user, "MANUAL-#{n}")

      assert new_order(user).order_number == number("ORD", 4)
    end

    test "the numbers of another year do not count", %{user: user} do
      old = insert_order(user, number("ORD", 99, @year - 1))

      Repo.update_all(from(o in Order, where: o.uuid == ^old.uuid),
        set: [inserted_at: DateTime.new!(Date.new!(@year - 1, 6, 1), ~T[12:00:00])]
      )

      assert new_order(user).order_number == number("ORD", 1)
      assert last_value("order", @year - 1) == nil
    end

    test "a number the caller supplies does not use up a counter value", %{user: user} do
      assert insert_order(user, "CUSTOM-1").order_number == "CUSTOM-1"
      assert last_value("order") == nil

      assert new_order(user).order_number == number("ORD", 2)
    end

    test "a changed prefix carries on the year's sequence", %{user: user} do
      assert new_order(user).order_number == number("ORD", 1)

      PhoenixKit.Settings.update_setting("billing_order_prefix", "SO")
      on_exit(fn -> PhoenixKit.Settings.update_setting("billing_order_prefix", "ORD") end)

      assert new_order(user).order_number == number("SO", 2)
    end

    test "a number typed by hand that collides is an error, not a raise", %{user: user} do
      insert_order(user, "TAKEN-1")

      assert {:error, changeset} =
               Billing.create_order(user, order_attrs(%{"order_number" => "TAKEN-1"}))

      assert %{order_number: [_]} = errors_on(changeset)
    end

    test "a generated number that collides is an error and keeps the counter where it was", %{
      user: user
    } do
      insert_order(user, number("ORD", 1))
      Repo.insert_all(@sequences, [%{scope: "order", year: @year, last_value: 0}])

      assert {:error, changeset} = Billing.create_order(user, order_attrs())
      assert %{order_number: [_]} = errors_on(changeset)
      assert last_value("order") == 0
    end
  end

  describe "invoices from an order" do
    setup %{user: user}, do: %{order: new_order(user)}

    test "numbers run on from 0001 and a deleted invoice's number is not reused", %{order: order} do
      first = new_invoice(order)
      second = new_invoice(order)
      assert first.invoice_number == number("INV", 1)
      assert second.invoice_number == number("INV", 2)

      Repo.delete!(first)
      assert new_invoice(order).invoice_number == number("INV", 3)

      Repo.delete!(second)
      assert new_invoice(order).invoice_number == number("INV", 4)
    end

    test "the order and invoice counters are separate", %{order: order} do
      assert new_invoice(order).invoice_number == number("INV", 1)
      assert last_value("order") == 1
      assert last_value("invoice") == 1
    end

    test "a counter-less year starts after the numbers already there", %{order: order} do
      for n <- [2, 7] do
        {:ok, _} = Billing.create_invoice_from_order(order, invoice_number: number("INV", n))
      end

      assert last_value("invoice") == nil
      assert new_invoice(order).invoice_number == number("INV", 8)
    end

    test "a number the caller supplies does not use up a counter value", %{order: order} do
      {:ok, invoice} = Billing.create_invoice_from_order(order, invoice_number: "OWN-1")
      assert invoice.invoice_number == "OWN-1"
      assert last_value("invoice") == nil

      assert new_invoice(order).invoice_number == number("INV", 2)
    end

    test "a supplied number that collides is an error, not a raise", %{order: order} do
      {:ok, _} = Billing.create_invoice_from_order(order, invoice_number: "OWN-1")

      assert {:error, changeset} =
               Billing.create_invoice_from_order(order, invoice_number: "OWN-1")

      assert %{invoice_number: [_]} = errors_on(changeset)
    end

    test "a generated number that collides is an error and keeps the counter where it was", %{
      order: order
    } do
      {:ok, _} = Billing.create_invoice_from_order(order, invoice_number: number("INV", 1))
      Repo.insert_all(@sequences, [%{scope: "invoice", year: @year, last_value: 0}])

      assert {:error, changeset} = Billing.create_invoice_from_order(order)
      assert %{invoice_number: [_]} = errors_on(changeset)
      assert last_value("invoice") == 0
    end

    test "a failed insert announces nothing", %{order: order} do
      Events.subscribe_invoices()
      {:ok, _} = Billing.create_invoice_from_order(order, invoice_number: "OWN-1")
      assert_receive {:invoice_created, _}

      assert {:error, _} = Billing.create_invoice_from_order(order, invoice_number: "OWN-1")
      refute_receive {:invoice_created, _}
    end
  end

  describe "standalone invoices" do
    defp standalone(user, extra \\ %{}) do
      Billing.create_invoice(
        user,
        Map.merge(
          %{
            total: Decimal.new("10.00"),
            currency: "EUR",
            billing_details: %{"email" => "b@example.com"}
          },
          extra
        )
      )
    end

    test "share the invoice counter with invoices from an order", %{user: user} do
      order = new_order(user)

      assert {:ok, first} = standalone(user)
      assert new_invoice(order).invoice_number == number("INV", 2)
      assert first.invoice_number == number("INV", 1)

      Repo.delete!(first)
      assert {:ok, next} = standalone(user)
      assert next.invoice_number == number("INV", 3)
    end

    test "a failed insert gives the number back", %{user: user} do
      assert {:ok, _} = standalone(user)
      assert {:error, %Ecto.Changeset{}} = standalone(user, %{total: Decimal.new("-1")})
      assert last_value("invoice") == 1

      assert {:ok, next} = standalone(user)
      assert next.invoice_number == number("INV", 2)
    end

    test "a number the caller supplies does not use up a counter value", %{user: user} do
      assert {:ok, invoice} = standalone(user, %{invoice_number: "OWN-1"})
      assert invoice.invoice_number == "OWN-1"
      assert last_value("invoice") == nil

      assert {:error, changeset} = standalone(user, %{invoice_number: "OWN-1"})
      assert %{invoice_number: [_]} = errors_on(changeset)
    end

    test "a counter-less year starts after the numbers already there", %{user: user} do
      assert {:ok, _} = standalone(user, %{invoice_number: number("INV", 12)})

      assert {:ok, next} = standalone(user)
      assert next.invoice_number == number("INV", 13)
    end

    test "the invoices of another year do not count", %{user: user} do
      {:ok, old} = standalone(user, %{invoice_number: number("INV", 40, @year - 1)})

      Repo.update_all(from(i in Invoice, where: i.uuid == ^old.uuid),
        set: [inserted_at: DateTime.new!(Date.new!(@year - 1, 6, 1), ~T[12:00:00])]
      )

      assert {:ok, next} = standalone(user)
      assert next.invoice_number == number("INV", 1)
    end
  end

  describe "receipts" do
    setup %{user: user} do
      order = new_order(user)
      %{order: order}
    end

    test "mark_invoice_paid numbers receipts from the receipt counter", %{order: order} do
      first = order |> new_invoice() |> sent()
      second = order |> new_invoice() |> sent()

      assert {:ok, paid_first} = Billing.mark_invoice_paid(first)
      assert {:ok, paid_second} = Billing.mark_invoice_paid(second)

      assert paid_first.receipt_number == number("RCP", 1)
      assert paid_second.receipt_number == number("RCP", 2)
    end

    test "a deleted invoice's receipt number is not reused", %{order: order} do
      first = order |> new_invoice() |> sent()
      second = order |> new_invoice() |> sent()
      third = order |> new_invoice() |> sent()

      assert {:ok, paid_first} = Billing.mark_invoice_paid(first)
      delete_invoice(paid_first)

      assert {:ok, paid_second} = Billing.mark_invoice_paid(second)
      assert paid_second.receipt_number == number("RCP", 2)

      delete_invoice(paid_second)
      assert {:ok, paid_third} = Billing.mark_invoice_paid(third)
      assert paid_third.receipt_number == number("RCP", 3)
    end

    test "generate_receipt takes the next receipt number", %{order: order} do
      invoice = order |> new_invoice() |> sent()
      assert {:ok, paid} = Billing.mark_invoice_paid(invoice)
      assert paid.receipt_number == number("RCP", 1)

      partly = order |> new_invoice() |> sent()

      {:ok, partly} =
        partly |> Ecto.Changeset.change(%{paid_amount: Decimal.new("4.00")}) |> Repo.update()

      assert {:ok, receipt} = Billing.generate_receipt(partly)
      assert receipt.receipt_number == number("RCP", 2)
      assert last_value("receipt") == 2
    end

    test "generate_receipt refusing an invoice does not use a number", %{order: order} do
      invoice = order |> new_invoice() |> sent()
      assert {:error, :no_payments} = Billing.generate_receipt(invoice)
      assert last_value("receipt") == nil
    end

    test "a payment that settles an invoice numbers its receipt from the same counter", %{
      order: order
    } do
      invoice = order |> new_invoice() |> sent()
      assert {:ok, _} = Billing.record_payment(invoice, %{amount: Decimal.new("10.00")}, nil)
      assert Billing.get_invoice(invoice.uuid).receipt_number == number("RCP", 1)

      other = order |> new_invoice() |> sent()
      assert {:ok, paid} = Billing.mark_invoice_paid(other)
      assert paid.receipt_number == number("RCP", 2)
    end

    test "a counter-less year starts after the receipt numbers already there", %{order: order} do
      invoice = order |> new_invoice() |> sent()

      invoice
      |> Ecto.Changeset.change(%{
        receipt_number: number("RCP", 9),
        receipt_generated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update!()

      other = order |> new_invoice() |> sent()
      assert {:ok, paid} = Billing.mark_invoice_paid(other)
      assert paid.receipt_number == number("RCP", 10)
    end

    test "the receipts of another year do not count", %{order: order} do
      invoice = order |> new_invoice() |> sent()

      invoice
      |> Ecto.Changeset.change(%{
        receipt_number: number("RCP", 30, @year - 1),
        receipt_generated_at: DateTime.new!(Date.new!(@year - 1, 6, 1), ~T[12:00:00])
      })
      |> Repo.update!()

      other = order |> new_invoice() |> sent()
      assert {:ok, paid} = Billing.mark_invoice_paid(other)
      assert paid.receipt_number == number("RCP", 1)
    end
  end
end
