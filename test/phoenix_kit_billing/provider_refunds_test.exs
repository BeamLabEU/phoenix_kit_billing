defmodule PhoenixKitBilling.ProviderRefundsTest do
  @moduledoc """
  `PhoenixKitBilling.refund_at_provider/3` over a stubbed Stripe
  (`:stripe_req_options` + `Req.Test`, no network).

  Before it, nothing in billing called `Providers.create_refund/4`: the admin's
  refund dialog booked a refund in the ledger (and voided the invoice at zero)
  while the customer's card was never refunded.
  """

  use PhoenixKitBilling.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Currency, Invoice, Providers, Transaction, WebhookProcessor}

  setup do
    Settings.update_setting("billing_stripe_enabled", "true")
    Settings.update_setting("billing_stripe_secret_key", "sk_test_123")
    Application.put_env(:phoenix_kit_billing, :stripe_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_billing, :stripe_req_options)
      Settings.update_setting("billing_stripe_enabled", "false")
      Settings.update_setting("billing_stripe_secret_key", "")
    end)

    Repo.delete_all(Currency)

    {:ok, _eur} =
      Billing.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        is_default: true,
        exchange_rate: "1.0"
      })

    :ok
  end

  # Answers every /v1/refunds call with a refund of the amount asked for (or
  # `full_cents` when none was), and reports it to the test. `during` runs where
  # Stripe would be answering.
  defp stub_refunds(opts \\ []) do
    test_pid = self()
    full_cents = Keyword.get(opts, :full_cents, 3000)
    during = Keyword.get(opts, :during, fn _params -> :ok end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      key = conn |> Plug.Conn.get_req_header("idempotency-key") |> List.first()
      send(test_pid, {:stripe, conn.method, conn.request_path, params, key})
      during.(params)

      amount = if params["amount"], do: String.to_integer(params["amount"]), else: full_cents

      Req.Test.json(conn, %{
        "id" => "re_" <> Integer.to_string(:erlang.phash2(key)),
        "object" => "refund",
        "amount" => amount,
        "currency" => "eur",
        "status" => "succeeded",
        "charge" => "ch_1",
        "payment_intent" => params["payment_intent"]
      })
    end)
  end

  defp stub_refund_error do
    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), :called)

      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "error" => %{"code" => "charge_disputed", "message" => "This charge is disputed"}
      })
    end)
  end

  # A sent EUR 30.00 invoice paid in full through Stripe Checkout (recorded under
  # the PaymentIntent, as `checkout.session.completed` records it).
  defp paid_invoice(total \\ "30.00") do
    user = fixture_user()

    {:ok, invoice} =
      Billing.create_invoice(user, %{
        total: Decimal.new(total),
        subtotal: Decimal.new(total),
        currency: "EUR",
        line_items: [
          %{"name" => "Class", "quantity" => 1, "unit_price" => total, "total" => total}
        ]
      })

    {:ok, invoice, _} = Billing.send_invoice(invoice, send_email: false)

    {:ok, _payment} =
      Billing.record_payment(
        invoice,
        %{
          amount: total,
          payment_method: "stripe",
          provider_transaction_id: "pi_123",
          provider_data: %{"payment_intent_id" => "pi_123"}
        },
        nil
      )

    Repo.get!(Invoice, invoice.uuid)
  end

  defp refunds(invoice) do
    Repo.all(
      from(t in Transaction,
        where: t.invoice_uuid == ^invoice.uuid and t.amount < 0,
        order_by: t.inserted_at
      )
    )
  end

  defp charge_refunded(refunded_cents) do
    %{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => "charge.refunded",
      "data" => %{
        "object" => %{
          "id" => "ch_1",
          "object" => "charge",
          "amount" => 3000,
          "amount_refunded" => refunded_cents,
          "currency" => "eur",
          "payment_intent" => "pi_123"
        }
      }
    }
  end

  defp deliver(payload) do
    {:ok, event} = Providers.handle_webhook_event(:stripe, payload)
    WebhookProcessor.process(event)
  end

  describe "a full refund" do
    test "refunds the payment at Stripe and records it, voiding the invoice" do
      invoice = paid_invoice()
      stub_refunds()

      assert {:ok, [%{refund: refund, transaction: %Transaction{} = tx}]} =
               Billing.refund_at_provider(invoice, %{description: "Class cancelled"})

      assert_received {:stripe, "POST", "/v1/refunds", params, key}
      assert params["payment_intent"] == "pi_123"
      assert params["amount"] == "3000"
      assert params["metadata[invoice_uuid]"] == invoice.uuid
      assert is_binary(key)

      assert Decimal.equal?(tx.amount, Decimal.new("-30.00"))
      assert tx.payment_method == "stripe"
      assert tx.provider_transaction_id == refund.id
      assert tx.description == "Class cancelled"
      assert tx.provider_data["payment_intent_id"] == "pi_123"
      assert tx.provider_data["charge_id"] == "ch_1"

      stored = Repo.get!(Invoice, invoice.uuid)
      assert Decimal.equal?(stored.paid_amount, Decimal.new(0))
      assert stored.status == "void"
    end

    test "the charge.refunded webhook that follows adds nothing" do
      invoice = paid_invoice()
      stub_refunds()

      assert {:ok, [_]} = Billing.refund_at_provider(invoice, %{})
      assert {:ok, :already_refunded} = deliver(charge_refunded(3000))

      assert [_one] = refunds(invoice)
    end

    test "a second full refund has nothing left and calls Stripe no more" do
      invoice = paid_invoice()
      stub_refunds()

      assert {:ok, [_]} = Billing.refund_at_provider(invoice, %{})
      assert_received {:stripe, _, _, _, _}

      assert {:error, :already_refunded} = Billing.refund_at_provider(invoice, %{})
      refute_received {:stripe, _, _, _, _}
    end
  end

  describe "a partial refund" do
    test "refunds the amount and leaves the invoice paid for the rest" do
      invoice = paid_invoice()
      stub_refunds()

      assert {:ok, [%{transaction: tx}]} =
               Billing.refund_at_provider(invoice, %{
                 amount: "10.00",
                 reason: "requested_by_customer"
               })

      assert_received {:stripe, "POST", "/v1/refunds", params, _key}
      assert params["amount"] == "1000"
      assert params["reason"] == "requested_by_customer"
      assert Decimal.equal?(tx.amount, Decimal.new("-10.00"))

      stored = Repo.get!(Invoice, invoice.uuid)
      assert Decimal.equal?(stored.paid_amount, Decimal.new("20.00"))
      assert stored.status == "paid"

      assert Decimal.equal?(
               Billing.provider_refundable_amount(stored, :stripe),
               Decimal.new("20.00")
             )
    end

    test "two partial refunds, then the webhook's running total, book 30.00 in all" do
      invoice = paid_invoice()
      stub_refunds()

      assert {:ok, _} = Billing.refund_at_provider(invoice, %{amount: "10.00"})

      assert {:ok, _} =
               Billing.refund_at_provider(Repo.get!(Invoice, invoice.uuid), %{amount: "5.00"})

      assert {:ok, :already_refunded} = deliver(charge_refunded(1500))

      total = invoice |> refunds() |> Enum.map(& &1.amount) |> Enum.reduce(&Decimal.add/2)
      assert Decimal.equal?(total, Decimal.new("-15.00"))
    end

    test "more than can be refunded is refused before Stripe is called" do
      invoice = paid_invoice()
      stub_refunds()

      assert {:error, :exceeds_paid_amount} =
               Billing.refund_at_provider(invoice, %{amount: "30.01"})

      assert {:error, :invalid_amount} = Billing.refund_at_provider(invoice, %{amount: "0"})
      assert {:error, :invalid_amount} = Billing.refund_at_provider(invoice, %{amount: "abc"})
      refute_received {:stripe, _, _, _, _}
    end

    test "a refund recorded by hand counts against what Stripe can still give back" do
      invoice = paid_invoice()
      stub_refunds()

      {:ok, _} =
        Billing.record_refund(
          invoice,
          %{amount: "25.00", payment_method: "stripe", description: "x"},
          nil
        )

      invoice = Repo.get!(Invoice, invoice.uuid)

      assert Decimal.equal?(Billing.provider_refundable_amount(invoice), Decimal.new("5.00"))

      assert {:ok, [%{transaction: tx}]} = Billing.refund_at_provider(invoice, %{})
      assert Decimal.equal?(tx.amount, Decimal.new("-5.00"))
    end
  end

  describe "an invoice paid in two Stripe payments" do
    # 10.00 through pi_old, then 20.00 through pi_new.
    defp two_payment_invoice do
      user = fixture_user()

      {:ok, invoice} =
        Billing.create_invoice(user, %{
          total: Decimal.new("30.00"),
          subtotal: Decimal.new("30.00"),
          currency: "EUR"
        })

      {:ok, invoice, _} = Billing.send_invoice(invoice, send_email: false)

      for {amount, pi} <- [{"10.00", "pi_old"}, {"20.00", "pi_new"}] do
        {:ok, _} =
          Billing.record_payment(
            Repo.get!(Invoice, invoice.uuid),
            %{
              amount: amount,
              payment_method: "stripe",
              provider_transaction_id: pi,
              provider_data: %{"payment_intent_id" => pi}
            },
            nil
          )
      end

      Repo.get!(Invoice, invoice.uuid)
    end

    test "an amount is taken from the newest payment first, then split onto the older" do
      invoice = two_payment_invoice()
      stub_refunds()

      assert {:ok, [first, second]} = Billing.refund_at_provider(invoice, %{amount: "25.00"})

      assert_received {:stripe, "POST", "/v1/refunds", %{"payment_intent" => "pi_new"} = p1, _}
      assert p1["amount"] == "2000"
      assert_received {:stripe, "POST", "/v1/refunds", %{"payment_intent" => "pi_old"} = p2, _}
      assert p2["amount"] == "500"

      assert first.payment.provider_transaction_id == "pi_new"
      assert second.payment.provider_transaction_id == "pi_old"
      assert Decimal.equal?(Repo.get!(Invoice, invoice.uuid).paid_amount, Decimal.new("5.00"))
    end

    test "a refund recorded by hand counts once, through paid_amount, not against each payment" do
      invoice = two_payment_invoice()
      stub_refunds()

      {:ok, _} =
        Billing.record_refund(
          invoice,
          %{amount: "5.00", payment_method: "stripe", description: "bank transfer back"},
          nil
        )

      invoice = Repo.get!(Invoice, invoice.uuid)
      assert Decimal.equal?(Billing.provider_refundable_amount(invoice), Decimal.new("25.00"))

      # Everything left: 20.00 from the newest payment, 5.00 from the older.
      assert {:ok, [_, _]} = Billing.refund_at_provider(invoice, %{})
      assert_received {:stripe, "POST", "/v1/refunds", %{"amount" => "2000"}, _}
      assert_received {:stripe, "POST", "/v1/refunds", %{"amount" => "500"}, _}

      stored = Repo.get!(Invoice, invoice.uuid)
      assert Decimal.equal?(stored.paid_amount, Decimal.new("0"))
      assert stored.status == "void"
    end

    test "an amount finer than the currency is refused before any payment is refunded" do
      invoice = two_payment_invoice()
      stub_refunds()

      # 20.00 from pi_new would go through, and 0.005 from pi_old be refused.
      assert {:error, :invalid_amount} = Billing.refund_at_provider(invoice, %{amount: "20.005"})

      refute_received {:stripe, _, _, _, _}
      assert refunds(invoice) == []
    end
  end

  describe "a refund only recorded, then reported by a provider without a running total" do
    test "is matched to the recorded row instead of booked again" do
      user = fixture_user()

      {:ok, invoice} =
        Billing.create_invoice(user, %{total: Decimal.new("30.00"), currency: "EUR"})

      {:ok, invoice, _} = Billing.send_invoice(invoice, send_email: false)

      {:ok, _} =
        Billing.record_payment(
          invoice,
          %{amount: "30.00", payment_method: "paypal", provider_transaction_id: "cap_1"},
          nil
        )

      {:ok, _} =
        Billing.record_refund(
          Repo.get!(Invoice, invoice.uuid),
          %{
            amount: "10.00",
            payment_method: "paypal",
            description: "refunded in PayPal",
            provider_data: %{"recorded_as_provider_refund" => true}
          },
          nil
        )

      event = %{
        event_id: "evt_paypal_refund_#{System.unique_integer([:positive])}",
        provider: :paypal,
        type: "refund.created",
        data: %{charge_id: "cap_1", refund_id: "rf_1", amount_refunded: 1000, currency: "EUR"}
      }

      capture_log(fn -> assert {:ok, :already_recorded} = WebhookProcessor.process(event) end)

      assert [row] = refunds(invoice)
      assert row.provider_transaction_id == "rf_1"
      assert Decimal.equal?(Repo.get!(Invoice, invoice.uuid).paid_amount, Decimal.new("20.00"))
    end
  end

  describe "a currency with three decimal places" do
    test "is refused for a provider refund and for a new invoice" do
      invoice = paid_invoice()
      stub_refunds()

      # EUR as if it carried three decimals (BHD, KWD): the ledger keeps two.
      eur = Billing.get_currency_by_code("EUR")
      {:ok, _} = Billing.update_currency(eur, %{decimal_places: 3})

      assert {:error, :currency_too_precise} =
               Billing.refund_at_provider(invoice, %{amount: "5.000"})

      refute_received {:stripe, _, _, _, _}

      assert {:error, %Ecto.Changeset{errors: [currency: _]}} =
               Billing.create_invoice(fixture_user(), %{total: Decimal.new("5"), currency: "EUR"})
    end
  end

  describe "idempotency" do
    test "a repeated request carries the same idempotency key, and books once" do
      invoice = paid_invoice()
      stub_refunds()

      # The same refund asked for twice from the same state: Stripe answers the
      # second with the refund it already made (same key, same refund id here).
      task_invoice = Repo.get!(Invoice, invoice.uuid)

      assert {:ok, [%{transaction: %Transaction{}}]} =
               Billing.refund_at_provider(task_invoice, %{
                 amount: "10.00",
                 idempotency_key: "click-1"
               })

      assert_received {:stripe, _, _, _, key1}
      assert key1 =~ "click-1:"

      # Same caller key: the provider would replay - the ledger already has the
      # refund id, so nothing more is booked.
      assert {:ok, [%{transaction: nil}]} =
               Billing.refund_at_provider(task_invoice, %{
                 amount: "10.00",
                 idempotency_key: "click-1"
               })

      assert_received {:stripe, _, _, _, ^key1}
      assert [_one] = refunds(invoice)
    end

    test "a webhook that books the refund while the call is in flight is not doubled" do
      invoice = paid_invoice()

      # Stripe's charge.refunded arrives (and is booked) before the refund call
      # returns.
      stub_refunds(during: fn _params -> {:ok, _} = deliver(charge_refunded(1000)) end)

      assert {:ok, [%{transaction: nil}]} =
               Billing.refund_at_provider(invoice, %{amount: "10.00"})

      assert [only] = refunds(invoice)
      assert Decimal.equal?(only.amount, Decimal.new("-10.00"))
    end
  end

  describe "refusals" do
    test "an invoice paid only by bank transfer has no provider payment" do
      user = fixture_user()

      {:ok, invoice} =
        Billing.create_invoice(user, %{total: Decimal.new("10.00"), currency: "EUR"})

      {:ok, invoice, _} = Billing.send_invoice(invoice, send_email: false)
      {:ok, _} = Billing.record_payment(invoice, %{amount: "10.00"}, nil)

      assert {:error, :no_provider_payments} =
               Billing.refund_at_provider(Repo.get!(Invoice, invoice.uuid), %{})
    end

    test "Stripe refusing leaves the ledger alone" do
      invoice = paid_invoice()
      stub_refund_error()

      capture_log(fn ->
        assert {:error, %{"code" => "charge_disputed"}} = Billing.refund_at_provider(invoice, %{})
      end)

      assert refunds(invoice) == []
      assert Repo.get!(Invoice, invoice.uuid).status == "paid"
    end

    test "an invoice in the trash is refused" do
      assert {:error, :invoice_trashed} =
               Billing.refund_at_provider(%Invoice{trashed_at: DateTime.utc_now()}, %{})
    end
  end

  describe "a refund that fails at Stripe later" do
    defp refund_failed(refund_id, cents, extra \\ %{}) do
      %{
        "id" => "evt_#{System.unique_integer([:positive])}",
        "type" => "charge.refund.updated",
        "data" => %{
          "object" =>
            Map.merge(
              %{
                "id" => refund_id,
                "object" => "refund",
                "status" => "failed",
                "failure_reason" => "expired_or_canceled_card",
                "charge" => "ch_1",
                "payment_intent" => "pi_123",
                "amount" => cents,
                "currency" => "eur"
              },
              extra
            )
        }
      }
    end

    defp reversals(invoice) do
      Repo.all(
        from(t in Transaction,
          where:
            t.invoice_uuid == ^invoice.uuid and t.amount > 0 and
              fragment("?->>'source'", t.provider_data) == "refund_failed"
        )
      )
    end

    test "is put back on the invoice once, flagged, with the refund row marked" do
      invoice = paid_invoice()
      stub_refunds()

      {:ok, [%{refund: refund, transaction: tx}]} =
        Billing.refund_at_provider(invoice, %{amount: "10.00"})

      log =
        capture_log(fn ->
          assert {:ok, :refund_failed} = deliver(refund_failed(refund.id, 1000))
        end)

      assert log =~ "did not get the money back"

      stored = Repo.get!(Invoice, invoice.uuid)
      assert Decimal.equal?(stored.paid_amount, Decimal.new("30.00"))

      assert [%{"amount" => "10.00", "refund_id" => refund_id}] =
               stored.metadata["refund_failures"]

      assert refund_id == refund.id

      assert [reversal] = reversals(invoice)
      assert Decimal.equal?(reversal.amount, Decimal.new("10.00"))
      assert reversal.provider_data["reverses_refund_uuid"] == tx.uuid

      row = Repo.get!(Transaction, tx.uuid)
      assert row.provider_data["refund_status"] == "failed"
      assert row.provider_data["reversed_by_uuid"] == reversal.uuid

      assert_activity_logged("billing.refund_failed_reversed", resource_uuid: reversal.uuid)

      # The same failure delivered again changes nothing.
      capture_log(fn ->
        assert {:ok, :refund_failed} = deliver(refund_failed(refund.id, 1000))
      end)

      assert length(reversals(invoice)) == 1
      assert Decimal.equal?(Repo.get!(Invoice, invoice.uuid).paid_amount, Decimal.new("30.00"))

      # What failed can be refunded again.
      assert Decimal.equal?(Billing.provider_refundable_amount(stored), Decimal.new("30.00"))
    end

    test "a failed full refund undoes the void it caused" do
      invoice = paid_invoice()
      stub_refunds()

      {:ok, [%{refund: refund}]} = Billing.refund_at_provider(invoice, %{})
      voided = Repo.get!(Invoice, invoice.uuid)
      assert voided.status == "void"
      assert voided.metadata["voided_by_refund"]["from"] == "paid"

      capture_log(fn -> deliver(refund_failed(refund.id, 3000)) end)

      restored = Repo.get!(Invoice, invoice.uuid)
      assert restored.status == "paid"
      assert restored.voided_at == nil
      assert Decimal.equal?(restored.paid_amount, Decimal.new("30.00"))
      refute restored.metadata["voided_by_refund"]
    end

    test "a void made by void_invoice/3 is never undone by a refund failure" do
      invoice = paid_invoice()
      stub_refunds()
      {:ok, [%{refund: refund}]} = Billing.refund_at_provider(invoice, %{amount: "10.00"})

      # A trail that is not this refund's.
      Repo.get!(Invoice, invoice.uuid)
      |> Ecto.Changeset.change(status: "void", metadata: %{"void" => %{"reason" => "x"}})
      |> Repo.update!()

      capture_log(fn -> deliver(refund_failed(refund.id, 1000)) end)

      assert Repo.get!(Invoice, invoice.uuid).status == "void"
    end

    test "a failed refund of an invoice partly refunded before comes back owed, not paid" do
      invoice = paid_invoice()
      stub_refunds()

      {:ok, [_]} = Billing.refund_at_provider(invoice, %{amount: "10.00"})
      {:ok, [%{refund: last}]} = Billing.refund_at_provider(invoice, %{})
      assert Repo.get!(Invoice, invoice.uuid).status == "void"

      capture_log(fn -> deliver(refund_failed(last.id, 2000)) end)

      restored = Repo.get!(Invoice, invoice.uuid)
      assert Decimal.equal?(restored.paid_amount, Decimal.new("20.00"))
      assert restored.status in ["sent", "overdue"]
      assert restored.paid_at == nil
    end

    test "an earlier refund failing un-voids the invoice too, and it can be refunded to zero again" do
      invoice = paid_invoice()
      stub_refunds()

      {:ok, [%{refund: first}]} = Billing.refund_at_provider(invoice, %{amount: "10.00"})
      {:ok, [_]} = Billing.refund_at_provider(invoice, %{})

      capture_log(fn -> deliver(refund_failed(first.id, 1000)) end)

      restored = Repo.get!(Invoice, invoice.uuid)
      assert restored.status in ["sent", "overdue"]
      assert Decimal.equal?(restored.paid_amount, Decimal.new("10.00"))

      # Refunding it again (a new key: the failed refund is not replayed) voids it again.
      assert {:ok, [%{refund: again}]} = Billing.refund_at_provider(restored, %{})
      assert again.id != first.id
      assert Repo.get!(Invoice, invoice.uuid).status == "void"
    end

    test "a failure matched by charge and amount, delivered again, is not reported unmatched" do
      invoice = paid_invoice()
      capture_log(fn -> deliver(charge_refunded(1000)) end)
      capture_log(fn -> deliver(refund_failed("re_unknown", 1000)) end)

      log =
        capture_log(fn ->
          assert {:ok, :refund_failed} = deliver(refund_failed("re_unknown", 1000))
        end)

      refute log =~ "no ledger row matches it"
      assert length(reversals(invoice)) == 1
    end

    test "a refund the webhook booked without its id is found by charge and amount" do
      invoice = paid_invoice()
      capture_log(fn -> assert {:ok, %Transaction{}} = deliver(charge_refunded(1000)) end)

      capture_log(fn ->
        assert {:ok, :refund_failed} = deliver(refund_failed("re_unknown", 1000))
      end)

      assert [_] = reversals(invoice)
      assert Decimal.equal?(Repo.get!(Invoice, invoice.uuid).paid_amount, Decimal.new("30.00"))
    end

    test "two rows that fit the charge and amount are not guessed between" do
      invoice = paid_invoice()
      capture_log(fn -> deliver(charge_refunded(1000)) end)
      capture_log(fn -> deliver(charge_refunded(2000)) end)

      log =
        capture_log(fn ->
          assert {:ok, :unmatched_refund} = deliver(refund_failed("re_unknown", 1000))
        end)

      assert log =~ "no ledger row matches it"
      assert reversals(invoice) == []
    end

    test "a refund update that did not fail stays an unknown event" do
      payload = %{
        "id" => "evt_1",
        "type" => "charge.refund.updated",
        "data" => %{"object" => %{"id" => "re_1", "object" => "refund", "status" => "succeeded"}}
      }

      assert {:error, :unknown_event} = Providers.handle_webhook_event(:stripe, payload)
    end
  end
end
