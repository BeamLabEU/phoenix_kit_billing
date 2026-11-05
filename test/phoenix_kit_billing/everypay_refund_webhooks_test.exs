defmodule PhoenixKitBilling.EveryPayRefundWebhooksTest do
  @moduledoc """
  EveryPay reports a refund by the state of the payment, re-fetched after each
  callback, so an event carries every refund made so far and not the one that
  raised it.

  The event id was `reference:state`: a second partial refund had the id of the
  first and was dropped as a duplicate, so it never reached the ledger. Told apart,
  it would have been recorded as the running total, on top of the first.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Providers, Transaction, WebhookProcessor}
  alias PhoenixKitBilling.Providers.EveryPay

  setup do
    {:ok, invoice} =
      Billing.create_invoice(fixture_user(), %{
        total: Decimal.new("100.00"),
        currency: "EUR",
        status: "sent",
        billing_details: %{"email" => "buyer@example.com"}
      })

    reference = "ep-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             deliver(%{
               "payment_reference" => reference,
               "payment_state" => "settled",
               "order_reference" => invoice.uuid,
               "amount" => 100.0,
               "currency" => "EUR"
             })

    {:ok, invoice: invoice, reference: reference}
  end

  defp deliver(payment) do
    {:ok, event} = Providers.handle_webhook_event(:everypay, payment)
    WebhookProcessor.process(event)
  end

  defp refunded(reference, state, refunds) do
    %{
      "payment_reference" => reference,
      "payment_state" => state,
      "currency" => "EUR",
      "refunds" => Enum.map(refunds, &%{"amount" => &1})
    }
  end

  defp refund_amounts(invoice) do
    from(t in Transaction,
      where: t.invoice_uuid == ^invoice.uuid and t.amount < 0,
      order_by: [asc: t.inserted_at],
      select: t.amount
    )
    |> Repo.all()
    |> Enum.map(&Decimal.to_string(Decimal.normalize(Decimal.abs(&1)), :normal))
  end

  test "a second partial refund is recorded, as what it adds", %{
    invoice: invoice,
    reference: reference
  } do
    assert {:ok, _} = deliver(refunded(reference, "partially_refunded", [30.0]))
    assert {:ok, _} = deliver(refunded(reference, "partially_refunded", [30.0, 20.0]))

    assert refund_amounts(invoice) == ["30", "20"]
    assert Decimal.equal?(Billing.get_invoice!(invoice.uuid).paid_amount, "50.00")
  end

  test "the same state fetched twice records nothing more", %{
    invoice: invoice,
    reference: reference
  } do
    assert {:ok, _} = deliver(refunded(reference, "partially_refunded", [30.0]))
    deliver(refunded(reference, "partially_refunded", [30.0]))

    assert refund_amounts(invoice) == ["30"]
  end

  test "the last refund of a payment settles the total", %{
    invoice: invoice,
    reference: reference
  } do
    assert {:ok, _} = deliver(refunded(reference, "partially_refunded", [30.0]))
    assert {:ok, _} = deliver(refunded(reference, "refunded", [30.0, 70.0]))

    assert refund_amounts(invoice) == ["30", "70"]

    stored = Billing.get_invoice!(invoice.uuid)
    assert Decimal.equal?(stored.paid_amount, "0.00")
    assert stored.status == "void"
  end

  test "a payment with no refund list keeps the amount it reports", %{
    invoice: invoice,
    reference: reference
  } do
    assert {:ok, _} =
             deliver(%{
               "payment_reference" => reference,
               "payment_state" => "partially_refunded",
               "currency" => "EUR",
               "refunded_amount" => 15.0
             })

    assert refund_amounts(invoice) == ["15"]
  end

  describe "handle_webhook_event/1" do
    test "gives each new total its own event id, and one total one id" do
      first = refunded("ep-1", "partially_refunded", [30.0])
      second = refunded("ep-1", "partially_refunded", [30.0, 20.0])

      assert {:ok, %{event_id: id_one}} = EveryPay.handle_webhook_event(first)
      assert {:ok, %{event_id: id_two}} = EveryPay.handle_webhook_event(second)
      assert {:ok, %{event_id: ^id_one}} = EveryPay.handle_webhook_event(first)

      assert id_one != id_two
    end

    test "reports the sum of the refund list as a running total" do
      payment = refunded("ep-1", "partially_refunded", [30.0, 20.0])

      assert {:ok, %{data: %{amount_refunded_total: 5000}}} =
               EveryPay.handle_webhook_event(payment)
    end

    test "keeps the event id of a settled payment, so stored events still match" do
      payment = %{
        "payment_reference" => "ep-1",
        "payment_state" => "settled",
        "order_reference" => "invoice-uuid",
        "amount" => 10.0,
        "currency" => "EUR"
      }

      assert {:ok, %{event_id: "ep-1:settled"}} = EveryPay.handle_webhook_event(payment)
    end
  end
end
