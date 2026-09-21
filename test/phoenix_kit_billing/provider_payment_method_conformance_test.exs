defmodule PhoenixKitBilling.ProviderPaymentMethodConformanceTest do
  @moduledoc """
  Every payment provider must be a valid transaction `payment_method`.

  `WebhookProcessor` records a provider-confirmed payment with
  `payment_method: "<provider>"`. A provider missing from
  `Transaction.payment_methods/0` fails that insert AFTER the customer has
  paid — which is exactly what happened to EveryPay: added as a provider,
  never added to the list, so every EveryPay payment (cards and the Baltic
  bank links alike) left its invoice unpaid.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Providers
  alias PhoenixKitBilling.Transaction

  test "every provider can be recorded as a transaction's payment method" do
    missing =
      Providers.all_providers()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.reject(&(&1 in Transaction.payment_methods()))

    assert missing == [],
           "providers a payment can arrive through but a transaction cannot record: #{inspect(missing)}"
  end
end
