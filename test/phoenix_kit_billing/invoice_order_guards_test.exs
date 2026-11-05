defmodule PhoenixKitBilling.InvoiceOrderGuardsTest do
  @moduledoc """
  An order and its invoice stay in step.

  An order edited while its invoice was open could be settled for its old total:
  `start_order_payment/2` refuses such an invoice, but an admin recording the payment
  never met that check. A part-paid invoice could be voided with the money still on
  it. And `mark_invoice_paid/2` moved the linked order only after its own commit, so
  a crash in between left a paid invoice on an unpaid order, with no order event.
  """

  use PhoenixKitBilling.DataCase, async: false
  use Oban.Testing, repo: PhoenixKitBilling.Test.Repo

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Order}
  alias PhoenixKitBilling.Web.InvoiceDetail.Helpers

  setup do
    start_supervised!({Oban, repo: Repo, testing: :manual})

    {:ok, order} =
      Billing.create_order(fixture_user(), %{
        "total" => Decimal.new("25.00"),
        "currency" => "EUR",
        "status" => "pending",
        "billing_snapshot" => %{"email" => "buyer@example.com"}
      })

    {:ok, order: order}
  end

  defp invoice!(order, status \\ "sent") do
    {:ok, invoice} = Billing.create_invoice_from_order(order)

    invoice
    |> Ecto.Changeset.change(status: status)
    |> Repo.update!()
  end

  describe "update_order/2 with an invoice on the order" do
    test "refuses a new total", %{order: order} do
      invoice!(order)

      assert {:error, :order_amount_invoiced} =
               Billing.update_order(order, %{"total" => "100.00"})

      assert Decimal.equal?(Repo.get!(Order, order.uuid).total, "25.00")
    end

    test "refuses a new currency", %{order: order} do
      invoice!(order)

      assert {:error, :order_amount_invoiced} =
               Billing.update_order(order, %{"currency" => "USD"})
    end

    test "counts a draft invoice: sending it would bill the old total", %{order: order} do
      invoice!(order, "draft")

      assert {:error, :order_amount_invoiced} =
               Billing.update_order(order, %{"total" => "100.00"})
    end

    test "still takes an edit that leaves the amount alone", %{order: order} do
      invoice!(order)

      assert {:ok, %Order{notes: "Ring twice"}} =
               Billing.update_order(order, %{"notes" => "Ring twice"})
    end

    test "reads 25 and 25.00 as the same total, as the form sends one back", %{order: order} do
      invoice!(order)

      assert {:ok, _} = Billing.update_order(order, %{"total" => "25", "notes" => "Same"})
    end

    test "takes the new total once the invoice is void", %{order: order} do
      invoice = invoice!(order)
      assert {:ok, _} = Billing.void_invoice(invoice)

      assert {:ok, %Order{} = updated} = Billing.update_order(order, %{"total" => "100.00"})
      assert Decimal.equal?(updated.total, "100.00")
    end

    test "takes the new total once a draft invoice is in the trash", %{order: order} do
      invoice = invoice!(order, "draft")
      assert {:ok, _} = Billing.trash_invoice(invoice)

      assert {:ok, _} = Billing.update_order(order, %{"total" => "100.00"})
    end

    test "gives no counter away on a refusal", %{order: order} do
      invoice!(order)

      assert {:error, :order_amount_invoiced} =
               Billing.update_order(order, %{
                 "total" => "100.00",
                 "order_number" => "ORD-#{Date.utc_today().year}-9000"
               })

      assert Repo.get!(Order, order.uuid).order_number == order.order_number
    end
  end

  test "update_order/2 without an invoice takes a new total", %{order: order} do
    assert {:ok, %Order{} = updated} = Billing.update_order(order, %{"total" => "100.00"})
    assert Decimal.equal?(updated.total, "100.00")
  end

  describe "void_invoice/3" do
    test "refuses an invoice that holds money: it has to be refunded first", %{order: order} do
      invoice = invoice!(order)

      assert {:ok, _} =
               Billing.record_payment(invoice, %{amount: "10.00", payment_method: "bank"}, nil)

      assert {:error, :invoice_has_payments} =
               Billing.void_invoice(Billing.get_invoice!(invoice.uuid))

      assert Repo.get!(Invoice, invoice.uuid).status == "sent"
    end

    test "decides on the stored row, not the caller's struct", %{order: order} do
      stale = invoice!(order)

      assert {:ok, _} =
               Billing.record_payment(stale, %{amount: "10.00", payment_method: "bank"}, nil)

      assert {:error, :invoice_has_payments} = Billing.void_invoice(stale)
    end

    test "voids an invoice nothing was paid on", %{order: order} do
      assert {:ok, %Invoice{status: "void"}} = Billing.void_invoice(invoice!(order))
    end
  end

  describe "mark_invoice_paid/2" do
    # A crash cannot be staged between two statements, but their order shows it:
    # nothing may commit between the invoice and the order.
    setup do
      handler_id = {__MODULE__, make_ref()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:phoenix_kit_billing, :test, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          step =
            cond do
              query == "begin" -> :begin
              query == "commit" -> :commit
              query =~ ~r/^UPDATE .*phoenix_kit_invoices/ -> :invoice_update
              query =~ ~r/^UPDATE .*phoenix_kit_orders/ -> :order_update
              true -> nil
            end

          if step && self() == test_pid, do: send(test_pid, {:step, step})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    defp flush_steps(acc \\ []) do
      receive do
        {:step, step} -> flush_steps([step | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "moves the order in the transaction that pays the invoice", %{order: order} do
      invoice = invoice!(order)
      flush_steps()

      assert {:ok, %Invoice{status: "paid"}} = Billing.mark_invoice_paid(invoice)

      steps = flush_steps()

      assert Enum.count(steps, &(&1 == :commit)) == 1,
             "more than one commit: #{inspect(steps)}"

      assert List.last(steps) == :commit
      assert :invoice_update in steps
      assert :order_update in steps
      assert Repo.get!(Order, order.uuid).status == "paid"
    end
  end

  describe "the invoice page's Fully Refunded mark" do
    test "follows what was paid, as the void of a full refund does" do
      invoice = %Invoice{total: Decimal.new("100.00"), paid_amount: Decimal.new("0")}
      payment = %{amount: Decimal.new("40.00")}
      refund = %{amount: Decimal.new("-40.00")}

      assert Helpers.fully_refunded?(invoice, [payment, refund])
    end

    test "stays off while money is left, or with no refund at all" do
      partly = %Invoice{total: Decimal.new("100.00"), paid_amount: Decimal.new("60.00")}
      unpaid = %Invoice{total: Decimal.new("100.00"), paid_amount: Decimal.new("0")}

      refute Helpers.fully_refunded?(partly, [%{amount: Decimal.new("-40.00")}])
      refute Helpers.fully_refunded?(unpaid, [])
    end
  end
end
