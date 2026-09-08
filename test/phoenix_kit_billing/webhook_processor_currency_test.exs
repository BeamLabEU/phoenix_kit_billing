defmodule PhoenixKitBilling.WebhookProcessorCurrencyTest do
  @moduledoc """
  §7 (Э5) of the per-domain-currency design, closing the gap code review
  found in the provider-only fix: `WebhookProcessor.calculate_payment_amount/2`
  and `refund_amount/3` used to divide a webhook's reported amount by a
  hard-coded 100. Before the provider side sent the correct amount to
  Stripe/PayPal/Razorpay/EveryPay, that hard-coded divide happened to
  CANCEL a zero-decimal currency's 100x overcharge and land on the right
  ledger number by accident. After the provider side is fixed, that same
  hard-coded divide would record the WRONG number instead: the invoice
  would never reach fully-paid, the receipt would understate what was
  actually charged, and a refund webhook would refund a hundredth of what
  the customer is owed.

  These tests process real, provider-shaped normalized events end to end
  through `WebhookProcessor.process/1` against a real invoice, so the
  amount asserted is the one actually written to the ledger — not just
  what an isolated helper function returns.
  """

  use PhoenixKitBilling.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.WebhookProcessor

  setup do
    Repo.delete_all(Currency)

    {:ok, _usd} =
      Billing.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _jpy} =
      Billing.create_currency(%{
        code: "JPY",
        name: "Yen",
        symbol: "¥",
        decimal_places: 0,
        exchange_rate: "150.0"
      })

    {:ok, _inr} =
      Billing.create_currency(%{
        code: "INR",
        name: "Rupee",
        symbol: "₹",
        exchange_rate: "83.0"
      })

    :ok
  end

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(
        %{
          email: "webhook-#{System.unique_integer([:positive])}@example.com",
          password: "hello world!123"
        },
        nil
      )

    user
  end

  defp invoice_fixture(user, currency, total_str) do
    {:ok, order} =
      Billing.create_order(user, %{
        "line_items" => [
          %{"name" => "Item", "quantity" => 1, "unit_price" => total_str, "total" => total_str}
        ],
        "subtotal" => Decimal.new(total_str),
        "total" => Decimal.new(total_str),
        "currency" => currency,
        "status" => "pending",
        "billing_snapshot" => %{"email" => user.email}
      })

    {:ok, invoice} = Billing.create_invoice_from_order(order)

    # An invoice must be ISSUED before it can take money - record_payment/3
    # refuses a draft (same pattern as regression/provider_payment_test.exs).
    {:ok, sent} =
      invoice
      |> Ecto.Changeset.change(%{status: "sent"})
      |> RepoHelper.repo().update()

    sent
  end

  describe "zero-decimal currency, end to end through the webhook processor" do
    test "a JPY payment webhook closes the invoice at 1000, not 10.00" do
      user = user_fixture()
      invoice = invoice_fixture(user, "JPY", "1000")

      assert {:ok, paid_invoice} =
               WebhookProcessor.process(%{
                 event_id: "evt_jpy_pay",
                 provider: :stripe,
                 type: "checkout.completed",
                 data: %{
                   mode: "payment",
                   invoice_uuid: invoice.uuid,
                   amount_total: 1000,
                   currency: "JPY"
                 }
               })

      assert paid_invoice.status == "paid"
      assert Decimal.equal?(paid_invoice.paid_amount, Decimal.new("1000"))
    end

    test "a JPY refund webhook records 1000, not 10.00" do
      user = user_fixture()
      invoice = invoice_fixture(user, "JPY", "1000")

      {:ok, _paid} =
        WebhookProcessor.process(%{
          event_id: "evt_jpy_pay2",
          provider: :stripe,
          type: "checkout.completed",
          data: %{
            mode: "payment",
            invoice_uuid: invoice.uuid,
            amount_total: 1000,
            currency: "JPY",
            payment_intent_id: "pi_jpy_1"
          }
        })

      assert {:ok, %{amount: refund_amount, currency: "JPY"}} =
               WebhookProcessor.process(%{
                 event_id: "evt_jpy_refund",
                 provider: :stripe,
                 type: "refund.created",
                 data: %{
                   charge_id: "pi_jpy_1",
                   amount_refunded: 1000,
                   currency: "JPY"
                 }
               })

      assert Decimal.equal?(refund_amount, Decimal.new("-1000"))
    end

    test "an unrecognized webhook currency falls back to the invoice's own balance, not a guess" do
      user = user_fixture()
      invoice = invoice_fixture(user, "JPY", "1000")

      assert {:ok, paid_invoice} =
               WebhookProcessor.process(%{
                 event_id: "evt_unknown_currency",
                 provider: :stripe,
                 type: "checkout.completed",
                 data: %{
                   mode: "payment",
                   invoice_uuid: invoice.uuid,
                   amount_total: 1000,
                   currency: "XXX"
                 }
               })

      # Falls back to invoice.total - paid_amount (1000 - 0), the SAME
      # explicit path used when a webhook carries no amount at all - not
      # 1000 interpreted under a wrong currency's assumptions.
      assert Decimal.equal?(paid_invoice.paid_amount, Decimal.new("1000"))
    end

    test "an amount with NO currency at all is logged as a normalizer bug, unlike a plain missing amount" do
      user = user_fixture()
      invoice = invoice_fixture(user, "JPY", "1000")

      log =
        capture_log(fn ->
          assert {:ok, paid_invoice} =
                   WebhookProcessor.process(%{
                     event_id: "evt_no_currency_at_all",
                     provider: :stripe,
                     type: "checkout.completed",
                     data: %{
                       mode: "payment",
                       invoice_uuid: invoice.uuid,
                       amount_total: 1000
                       # no :currency key at all - a normalizer bug, since
                       # every provider's own handler already attaches one.
                     }
                   })

          assert Decimal.equal?(paid_invoice.paid_amount, Decimal.new("1000"))
        end)

      assert log =~ "arrived with no currency"
    end

    test "an event with no amount field at all is the ordinary case and logs nothing" do
      user = user_fixture()
      invoice = invoice_fixture(user, "JPY", "1000")

      log =
        capture_log(fn ->
          assert {:ok, paid_invoice} =
                   WebhookProcessor.process(%{
                     event_id: "evt_no_amount_field",
                     provider: :stripe,
                     type: "checkout.completed",
                     data: %{mode: "payment", invoice_uuid: invoice.uuid}
                   })

          assert Decimal.equal?(paid_invoice.paid_amount, Decimal.new("1000"))
        end)

      refute log =~ "arrived with no currency"
      refute log =~ "is not in this shop's"
    end
  end

  describe "two-decimal currency is unchanged across all four providers (regression guard)" do
    test "stripe: a $100.00 checkout.completed records exactly 100.00" do
      user = user_fixture()
      invoice = invoice_fixture(user, "USD", "100.00")

      assert {:ok, paid_invoice} =
               WebhookProcessor.process(%{
                 event_id: "evt_stripe_pay",
                 provider: :stripe,
                 type: "checkout.completed",
                 data: %{
                   mode: "payment",
                   invoice_uuid: invoice.uuid,
                   amount_total: 10_000,
                   currency: "USD"
                 }
               })

      assert Decimal.equal?(paid_invoice.paid_amount, Decimal.new("100.00"))
    end

    test "paypal: a $100.00 payment.succeeded records exactly 100.00" do
      user = user_fixture()
      invoice = invoice_fixture(user, "USD", "100.00")

      assert {:ok, paid_invoice} =
               WebhookProcessor.process(%{
                 event_id: "evt_paypal_pay",
                 provider: :paypal,
                 type: "payment.succeeded",
                 data: %{
                   invoice_uuid: invoice.uuid,
                   charge_id: "cap_1",
                   amount: 10_000,
                   currency: "USD"
                 }
               })

      assert Decimal.equal?(paid_invoice.paid_amount, Decimal.new("100.00"))
    end

    test "razorpay: a $100.00 checkout.completed records exactly 100.00" do
      user = user_fixture()
      invoice = invoice_fixture(user, "USD", "100.00")

      assert {:ok, paid_invoice} =
               WebhookProcessor.process(%{
                 event_id: "evt_razorpay_pay",
                 provider: :razorpay,
                 type: "checkout.completed",
                 data: %{
                   mode: "payment",
                   invoice_uuid: invoice.uuid,
                   amount_total: 10_000,
                   currency: "USD"
                 }
               })

      assert Decimal.equal?(paid_invoice.paid_amount, Decimal.new("100.00"))
    end

    test "razorpay: a real ₹199.99 INR payment and refund are unchanged end to end" do
      # INR specifically, not just a stand-in 2-decimal currency: Razorpay
      # is INR-primary, and INR is every current real user of this
      # provider (§7/Э5 review). 19999 paise, exactly as before this fix.
      user = user_fixture()
      invoice = invoice_fixture(user, "INR", "199.99")

      assert {:ok, paid_invoice} =
               WebhookProcessor.process(%{
                 event_id: "evt_razorpay_inr_pay",
                 provider: :razorpay,
                 type: "checkout.completed",
                 data: %{
                   mode: "payment",
                   invoice_uuid: invoice.uuid,
                   amount_total: 19_999,
                   currency: "INR",
                   payment_intent_id: "pay_inr_1"
                 }
               })

      assert Decimal.equal?(paid_invoice.paid_amount, Decimal.new("199.99"))

      assert {:ok, %{amount: refund_amount}} =
               WebhookProcessor.process(%{
                 event_id: "evt_razorpay_inr_refund",
                 provider: :razorpay,
                 type: "refund.created",
                 data: %{
                   charge_id: "pay_inr_1",
                   amount_refunded: 19_999,
                   currency: "INR"
                 }
               })

      assert Decimal.equal?(refund_amount, Decimal.new("-199.99"))
    end

    test "everypay: a $100.00 checkout.completed (amount key, not amount_total) records exactly 100.00" do
      user = user_fixture()
      invoice = invoice_fixture(user, "USD", "100.00")

      assert {:ok, paid_invoice} =
               WebhookProcessor.process(%{
                 event_id: "evt_everypay_pay",
                 provider: :everypay,
                 type: "checkout.completed",
                 data: %{
                   mode: "payment",
                   invoice_uuid: invoice.uuid,
                   amount: 10_000,
                   currency: "USD"
                 }
               })

      assert Decimal.equal?(paid_invoice.paid_amount, Decimal.new("100.00"))
    end

    test "a $100.00 refund records exactly -100.00 (regression guard for refund_amount/3)" do
      user = user_fixture()
      invoice = invoice_fixture(user, "USD", "100.00")

      {:ok, _paid} =
        WebhookProcessor.process(%{
          event_id: "evt_usd_pay",
          provider: :stripe,
          type: "checkout.completed",
          data: %{
            mode: "payment",
            invoice_uuid: invoice.uuid,
            amount_total: 10_000,
            currency: "USD",
            payment_intent_id: "pi_usd_1"
          }
        })

      assert {:ok, %{amount: refund_amount}} =
               WebhookProcessor.process(%{
                 event_id: "evt_usd_refund",
                 provider: :stripe,
                 type: "refund.created",
                 data: %{
                   charge_id: "pi_usd_1",
                   amount_refunded: 10_000,
                   currency: "USD"
                 }
               })

      assert Decimal.equal?(refund_amount, Decimal.new("-100.00"))
    end
  end
end
