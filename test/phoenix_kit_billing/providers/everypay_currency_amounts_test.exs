defmodule PhoenixKitBilling.Providers.EveryPayCurrencyAmountsTest do
  @moduledoc """
  §7 (Э5) of the per-domain-currency design: `PhoenixKitBilling.Providers.EveryPay`'s
  `decimal_to_amount/1` rounded every outbound amount to exactly two
  decimal places regardless of currency — padding a zero-decimal currency
  harmlessly, but silently dropping a three-decimal currency's third
  digit. `create_checkout_session/2` is the one call site with the
  invoice's own currency on hand (`charge_payment_method/3` and
  `create_refund/3` have none — EveryPay's account fixes the currency
  server-side, and inventing one there would be exactly the guess §7/Э5
  forbids), so it now validates/rounds against that currency's real
  `decimal_places` via `MinorUnits`, refusing rather than dropping.

  `ensure_configured/0` (unlike Razorpay's per-request Basic auth) DOES
  run before the currency check, so a fake account is configured below
  purely so these tests reach that check instead of short-circuiting on
  `{:error, :not_configured}` first — same reasoning as the Stripe/PayPal
  suites. No test here exercises a currency EveryPay would actually
  accept, since that requires a real API call this suite cannot stub.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.Providers.EveryPay

  setup do
    Settings.update_setting("billing_everypay_enabled", "true")
    Settings.update_setting("billing_everypay_api_username", "fake_user")
    Settings.update_setting("billing_everypay_api_secret", "fake_secret")
    Settings.update_setting("billing_everypay_account_name", "EUR3D1")

    Repo.delete_all(Currency)

    {:ok, _eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
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

    on_exit(fn ->
      Settings.update_setting("billing_everypay_enabled", "false")
      Settings.update_setting("billing_everypay_api_username", "")
      Settings.update_setting("billing_everypay_api_secret", "")
      Settings.update_setting("billing_everypay_account_name", "")
    end)

    :ok
  end

  describe "create_checkout_session/2" do
    test "refuses an unrecognized invoice currency before any network call" do
      invoice = %{uuid: Ecto.UUID.generate(), total: Decimal.new("10.00"), currency: "XXX"}

      assert {:error, :unknown_currency} =
               EveryPay.create_checkout_session(invoice, success_url: "https://example.com/ok")
    end

    test "refuses a JPY total with a fraction — JPY has zero decimal places" do
      invoice = %{uuid: Ecto.UUID.generate(), total: Decimal.new("10.50"), currency: "JPY"}

      assert {:error, :fractional_amount} =
               EveryPay.create_checkout_session(invoice, success_url: "https://example.com/ok")
    end
  end
end
