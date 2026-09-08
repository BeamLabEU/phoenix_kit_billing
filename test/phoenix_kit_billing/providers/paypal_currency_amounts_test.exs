defmodule PhoenixKitBilling.Providers.PayPalCurrencyAmountsTest do
  @moduledoc """
  §7 (Э5) of the per-domain-currency design: `PhoenixKitBilling.Providers.PayPal`
  used to format every amount with a hard-coded two decimal places, which
  is wrong for a zero-decimal currency (JPY — PayPal rejects a decimal
  point on a `NO_DECIMALS` currency) or a three-decimal one (BHD —
  silently truncates the third digit). The actual scaling/refusal
  arithmetic is covered exhaustively in `minor_units_test.exs`; this file
  proves PayPal's three call sites (charge, refund, checkout-session
  order) route through it and refuse — before any network call — an
  unrecognized code or an over-precise amount.

  Unlike Stripe, EVERY PayPal call here first exchanges OAuth credentials
  over the network (`get_access_token/0`) — so the currency/amount check
  had to move BEFORE that exchange (see the comments in `paypal.ex`) for
  these failures to be observable without a live PayPal sandbox. No test
  here exercises a currency PayPal would actually accept, since that
  requires the OAuth round trip this suite has no way to stub.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.PaymentMethod
  alias PhoenixKitBilling.Providers.PayPal

  setup do
    # Deliberately NOT configuring real PayPal credentials: every test
    # here asserts the currency/amount failure happens BEFORE
    # get_access_token/0 would even notice credentials are missing.
    Repo.delete_all(Currency)

    {:ok, _usd} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _jpy} =
      PhoenixKitBilling.create_currency(%{
        code: "JPY",
        name: "Yen",
        symbol: "¥",
        decimal_places: 0,
        exchange_rate: "150.0"
      })

    :ok
  end

  @pm %PaymentMethod{
    provider_customer_id: "cus_x",
    provider_payment_method_id: "pm_x"
  }

  describe "charge_payment_method/3" do
    test "refuses an unrecognized currency code before the OAuth round trip" do
      assert {:error, :unknown_currency} =
               PayPal.charge_payment_method(@pm, Decimal.new("10.00"), currency: "XXX")
    end

    test "refuses a JPY amount with a fraction — JPY has zero decimal places" do
      assert {:error, :fractional_amount} =
               PayPal.charge_payment_method(@pm, Decimal.new("10.50"), currency: "JPY")
    end

    test "still raises KeyError without :currency at all (§7.1 unchanged)" do
      assert_raise KeyError, fn ->
        PayPal.charge_payment_method(@pm, Decimal.new("10.00"), [])
      end
    end
  end

  describe "create_refund/3" do
    test "a partial refund refuses an unrecognized currency code before the OAuth round trip" do
      assert {:error, :unknown_currency} =
               PayPal.create_refund("cap_x", Decimal.new("10.00"), currency: "XXX")
    end

    test "a partial refund refuses a JPY amount with a fraction" do
      assert {:error, :fractional_amount} =
               PayPal.create_refund("cap_x", Decimal.new("10.50"), currency: "JPY")
    end
  end

  describe "create_checkout_session/2" do
    test "refuses an unrecognized invoice currency before the OAuth round trip" do
      invoice = %{
        uuid: Ecto.UUID.generate(),
        total: Decimal.new("10.00"),
        currency: "XXX",
        invoice_number: "INV-1"
      }

      assert {:error, :unknown_currency} =
               PayPal.create_checkout_session(invoice,
                 success_url: "https://example.com/ok",
                 cancel_url: "https://example.com/cancel"
               )
    end

    test "refuses a JPY total with a fraction" do
      invoice = %{
        uuid: Ecto.UUID.generate(),
        total: Decimal.new("10.50"),
        currency: "JPY",
        invoice_number: "INV-1"
      }

      assert {:error, :fractional_amount} =
               PayPal.create_checkout_session(invoice,
                 success_url: "https://example.com/ok",
                 cancel_url: "https://example.com/cancel"
               )
    end

    test "an invoice with no currency at all still raises ArgumentError (§7.1 unchanged)" do
      invoice = %{
        uuid: Ecto.UUID.generate(),
        total: Decimal.new("10.00"),
        currency: nil,
        invoice_number: "INV-1"
      }

      assert_raise ArgumentError, ~r/invoice has no currency/, fn ->
        PayPal.create_checkout_session(invoice,
          success_url: "https://example.com/ok",
          cancel_url: "https://example.com/cancel"
        )
      end
    end
  end
end
