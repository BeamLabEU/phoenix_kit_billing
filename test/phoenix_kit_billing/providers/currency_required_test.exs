defmodule PhoenixKitBilling.Providers.CurrencyRequiredTest do
  @moduledoc """
  Pins §7.1 of the currency design spec: the payment providers must never
  silently fall back to a hardcoded currency when a caller omits
  `:currency`. Plain `ExUnit.Case` (not `DataCase`) — no database access
  needed, and this suite must actually execute rather than be excluded as
  `:integration`.

  The provider table below is enumerated against
  `Providers.all_providers/0`, so a provider added to the registry cannot
  quietly skip this rule: the coverage test fails until it is classified
  here as either requiring a currency or exempt with a reason.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Providers

  @pm %PhoenixKitBilling.PaymentMethod{
    provider_customer_id: "cus_x",
    provider_payment_method_id: "pm_x"
  }

  # provider => :requires_currency | {:exempt, reason}
  @classification %{
    stripe: :requires_currency,
    paypal: :requires_currency,
    razorpay: :requires_currency,
    # EveryPay charges in the currency fixed by the processing account and
    # sends no currency field at all — there is nothing to default.
    everypay: {:exempt, "currency is fixed by the EveryPay processing account"}
  }

  for {name, :requires_currency} <-
        Enum.filter(@classification, &match?({_, :requires_currency}, &1)) do
    test "#{name}: charge_payment_method/3 refuses to charge without an explicit currency" do
      module = Providers.get_provider(unquote(name))

      assert_raise KeyError, fn ->
        module.charge_payment_method(@pm, Decimal.new("1.00"), [])
      end
    end
  end

  test "every registered provider is classified — a new one cannot skip §7.1" do
    assert Enum.sort(Map.keys(@classification)) == Enum.sort(Providers.all_providers()),
           """
           The provider registry and this suite's classification table have drifted.

           registry:       #{inspect(Enum.sort(Providers.all_providers()))}
           classified here: #{inspect(Enum.sort(Map.keys(@classification)))}

           Classify the new provider as :requires_currency (and drop any
           hardcoded currency fallback it ships with) or {:exempt, reason}.
           """
  end
end
