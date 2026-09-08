defmodule PhoenixKitBilling.Providers.RazorpayCurrencyAmountsTest do
  @moduledoc """
  §7 (Э5) of the per-domain-currency design: `PhoenixKitBilling.Providers.Razorpay`
  converted every amount to Razorpay's minor unit ("paise" for INR) with a
  hard-coded ×100 across four call sites (`create_order/1`,
  `create_order_for_recurring/2`, `do_create_refund/3`, `invoice_to_opts/1`),
  identically to Stripe's original bug — a zero-decimal currency (JPY,
  KRW) would be charged one hundred times its intended amount. Fixed by
  extending the same `MinorUnits` treatment as Stripe/PayPal; this file
  proves the three public entrypoints route through it and refuse — before
  any network call — an unrecognized code or an over-precise amount.

  Razorpay makes no separate token-exchange step before these calls (HTTP
  Basic auth per-request, unlike PayPal's OAuth), so unlike PayPal these
  tests need no fake credentials at all: the currency/amount check happens
  before `get_credentials/0` is ever consulted.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.PaymentMethod
  alias PhoenixKitBilling.Providers.Razorpay

  setup do
    Repo.delete_all(Currency)

    {:ok, _inr} =
      PhoenixKitBilling.create_currency(%{
        code: "INR",
        name: "Rupee",
        symbol: "₹",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _jpy} =
      PhoenixKitBilling.create_currency(%{
        code: "JPY",
        name: "Yen",
        symbol: "¥",
        decimal_places: 0,
        exchange_rate: "0.55"
      })

    :ok
  end

  @pm %PaymentMethod{
    provider_customer_id: "cust_x",
    provider_payment_method_id: "token_x"
  }

  describe "charge_payment_method/3" do
    test "refuses an unrecognized currency code before any network call" do
      assert {:error, :unknown_currency} =
               Razorpay.charge_payment_method(@pm, Decimal.new("10.00"), currency: "XXX")
    end

    test "refuses a JPY amount with a fraction — JPY has zero decimal places" do
      assert {:error, :fractional_amount} =
               Razorpay.charge_payment_method(@pm, Decimal.new("10.50"), currency: "JPY")
    end

    test "still raises KeyError without :currency at all (§7.1 unchanged)" do
      assert_raise KeyError, fn ->
        Razorpay.charge_payment_method(@pm, Decimal.new("10.00"), [])
      end
    end

    test "a real INR amount (every current user of this provider) is not refused" do
      # No credentials configured - :not_configured proves the amount and
      # currency were valid enough to pass MinorUnits and reach the
      # network-call attempt, not that a real charge succeeded.
      assert {:error, :not_configured} =
               Razorpay.charge_payment_method(@pm, Decimal.new("199.99"), currency: "INR")
    end
  end

  describe "create_refund/3" do
    test "a partial refund refuses an unrecognized currency code before any network call" do
      assert {:error, :unknown_currency} =
               Razorpay.create_refund("pay_x", Decimal.new("10.00"), currency: "XXX")
    end

    test "a partial refund refuses a JPY amount with a fraction" do
      assert {:error, :fractional_amount} =
               Razorpay.create_refund("pay_x", Decimal.new("10.50"), currency: "JPY")
    end

    test "a full refund (amount: nil) does not require :currency at all" do
      # No credentials configured either - this proves the refusal really
      # happens before a network call, not that a real refund succeeded.
      assert {:error, :not_configured} = Razorpay.create_refund("pay_x", nil, [])
    end

    test "a partial refund in real INR is not refused" do
      assert {:error, :not_configured} =
               Razorpay.create_refund("pay_x", Decimal.new("199.99"), currency: "INR")
    end
  end

  describe "create_checkout_session/2" do
    test "refuses an unrecognized invoice currency before any network call" do
      invoice = %{
        uuid: Ecto.UUID.generate(),
        total: Decimal.new("10.00"),
        currency: "XXX",
        invoice_number: "INV-1"
      }

      assert {:error, :unknown_currency} =
               Razorpay.create_checkout_session(invoice, success_url: "https://example.com/ok")
    end

    test "refuses a JPY total with a fraction" do
      invoice = %{
        uuid: Ecto.UUID.generate(),
        total: Decimal.new("10.50"),
        currency: "JPY",
        invoice_number: "INV-1"
      }

      assert {:error, :fractional_amount} =
               Razorpay.create_checkout_session(invoice, success_url: "https://example.com/ok")
    end

    test "an invoice with no currency at all still raises ArgumentError (§7.1 unchanged)" do
      invoice = %{
        uuid: Ecto.UUID.generate(),
        total: Decimal.new("10.00"),
        currency: nil,
        invoice_number: "INV-1"
      }

      assert_raise ArgumentError, ~r/invoice has no currency/, fn ->
        Razorpay.create_checkout_session(invoice, success_url: "https://example.com/ok")
      end
    end

    test "a real INR invoice total is not refused" do
      invoice = %{
        uuid: Ecto.UUID.generate(),
        total: Decimal.new("199.99"),
        currency: "INR",
        invoice_number: "INV-1"
      }

      assert {:error, :not_configured} =
               Razorpay.create_checkout_session(invoice, success_url: "https://example.com/ok")
    end
  end
end
