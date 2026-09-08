defmodule PhoenixKitBilling.CurrencyRequestTest do
  @moduledoc """
  `PhoenixKitBilling.Currency.put_request_currency/1` and
  `get_request_currency/0` — the request-scoped display-currency code
  (§4.1). Plain `Process` state, no database involved, so this runs as a
  pure unit test regardless of whether the integration DataCase suite
  is available.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Currency

  test "put/get round-trips a code, nil and blank clear it" do
    assert :ok = Currency.put_request_currency("EUR")
    assert Currency.get_request_currency() == "EUR"

    assert :ok = Currency.put_request_currency("")
    assert Currency.get_request_currency() == nil

    Currency.put_request_currency("eur")
    assert Currency.get_request_currency() == "EUR"

    assert :ok = Currency.put_request_currency(nil)
    assert Currency.get_request_currency() == nil

    refute Map.has_key?(Map.new(Process.get()), :phoenix_kit_billing_request_currency)
  end
end
