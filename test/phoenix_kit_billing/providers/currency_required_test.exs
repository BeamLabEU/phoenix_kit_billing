defmodule PhoenixKitBilling.Providers.CurrencyRequiredTest do
  @moduledoc """
  Pins §7.1 of the currency design spec: the payment providers must never
  silently fall back to `"EUR"` when a caller omits `:currency`. Plain
  `ExUnit.Case` (not `DataCase`) — no database access needed, and this
  suite must actually execute rather than be excluded as `:integration`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Providers.{PayPal, Stripe}

  @pm %PhoenixKitBilling.PaymentMethod{
    provider_customer_id: "cus_x",
    provider_payment_method_id: "pm_x"
  }

  test "Stripe.charge_payment_method/3 refuses to charge without an explicit currency" do
    assert_raise KeyError, fn -> Stripe.charge_payment_method(@pm, Decimal.new("1.00"), []) end
  end

  test "PayPal.charge_payment_method/3 refuses to charge without an explicit currency" do
    assert_raise KeyError, fn -> PayPal.charge_payment_method(@pm, Decimal.new("1.00"), []) end
  end
end
