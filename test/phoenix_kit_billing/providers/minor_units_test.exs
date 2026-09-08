defmodule PhoenixKitBilling.Providers.MinorUnitsTest do
  @moduledoc """
  §7 (Э5) of the per-domain-currency design: the payment providers
  hard-coded a ×100 factor converting between a shop-side `Decimal` amount
  and the provider's own minor unit, which is only correct for two-decimal
  currencies (USD/EUR/GBP). A zero-decimal currency (JPY, KRW) sent through
  that factor charges a customer one hundred times the intended amount; a
  three-decimal one (BHD, KWD) truncates to a hundredth of a unit.

  `PhoenixKitBilling.Providers.MinorUnits` replaces the hard-coded factor
  with `10^decimal_places`, read from `phoenix_kit_currencies` per-code,
  for BOTH providers that speak this file (Stripe, PayPal — see
  `stripe_currency_amounts_test.exs` / `paypal_currency_amounts_test.exs`
  for how each provider actually uses it).

  `DataCase`-based: `decimal_places` is looked up in the currency table,
  same as `Currency.present/3`.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.Providers.MinorUnits

  setup do
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

    {:ok, _bhd} =
      PhoenixKitBilling.create_currency(%{
        code: "BHD",
        name: "Bahraini Dinar",
        symbol: "BD",
        decimal_places: 3,
        exchange_rate: "0.377"
      })

    :ok
  end

  describe "to_minor_units/2" do
    test "a two-decimal currency behaves exactly as the old hard-coded ×100 (regression guard)" do
      assert {:ok, 9_999} = MinorUnits.to_minor_units(Decimal.new("99.99"), "USD")
      assert {:ok, 100} = MinorUnits.to_minor_units(Decimal.new("1.00"), "USD")
      assert {:ok, 0} = MinorUnits.to_minor_units(Decimal.new("0"), "USD")
    end

    test "a zero-decimal currency is sent UNMULTIPLIED — not ×100" do
      assert {:ok, 1000} = MinorUnits.to_minor_units(Decimal.new("1000"), "JPY")
      assert {:ok, 1} = MinorUnits.to_minor_units(Decimal.new("1"), "JPY")
    end

    test "a three-decimal currency uses a factor of a thousand, not a hundred" do
      assert {:ok, 10_125} = MinorUnits.to_minor_units(Decimal.new("10.125"), "BHD")
      assert {:ok, 1000} = MinorUnits.to_minor_units(Decimal.new("1.000"), "BHD")
    end

    test "lower-case currency codes resolve the same as upper-case (providers send lower-case)" do
      assert {:ok, 1000} = MinorUnits.to_minor_units(Decimal.new("1000"), "jpy")
    end

    test "a code this shop's currency table has never heard of is REFUSED, not guessed" do
      assert {:error, :unknown_currency} =
               MinorUnits.to_minor_units(Decimal.new("10.00"), "XXX")
    end

    test "an amount with more precision than the currency allows is refused, not silently rounded" do
      # JPY has 0 decimal places — a fractional yen cannot be sent to Stripe.
      assert {:error, :fractional_amount} = MinorUnits.to_minor_units(Decimal.new("10.5"), "JPY")
      # USD has 2 — a third decimal digit would be silently dropped by a
      # naive round; refusing is the caller-visible signal instead.
      assert {:error, :fractional_amount} =
               MinorUnits.to_minor_units(Decimal.new("10.005"), "USD")
    end

    test "a negative amount (refund direction) converts with the same factor" do
      assert {:ok, -9_999} = MinorUnits.to_minor_units(Decimal.new("-99.99"), "USD")
    end
  end

  describe "from_minor_units/2 — the inverse" do
    test "two-decimal currency" do
      assert {:ok, amount} = MinorUnits.from_minor_units(9_999, "USD")
      assert Decimal.equal?(amount, Decimal.new("99.99"))
    end

    test "zero-decimal currency is read back UNMULTIPLIED" do
      assert {:ok, amount} = MinorUnits.from_minor_units(1000, "JPY")
      assert Decimal.equal?(amount, Decimal.new("1000"))
    end

    test "three-decimal currency" do
      assert {:ok, amount} = MinorUnits.from_minor_units(10_125, "BHD")
      assert Decimal.equal?(amount, Decimal.new("10.125"))
    end

    test "unknown currency code is refused" do
      assert {:error, :unknown_currency} = MinorUnits.from_minor_units(1000, "XXX")
    end
  end

  describe "round-trip: from_minor_units(to_minor_units(amount)) == amount" do
    for {code, amount} <- [{"USD", "99.99"}, {"JPY", "1000"}, {"BHD", "10.125"}] do
      test "#{code} #{amount}" do
        amount = Decimal.new(unquote(amount))
        {:ok, minor} = MinorUnits.to_minor_units(amount, unquote(code))
        {:ok, back} = MinorUnits.from_minor_units(minor, unquote(code))
        assert Decimal.equal?(back, amount)
      end
    end
  end

  describe "decimal_places/1" do
    test "resolves a known currency's decimal_places" do
      assert {:ok, 2} = MinorUnits.decimal_places("USD")
      assert {:ok, 0} = MinorUnits.decimal_places("JPY")
      assert {:ok, 3} = MinorUnits.decimal_places("BHD")
    end

    test "refuses an unknown code" do
      assert {:error, :unknown_currency} = MinorUnits.decimal_places("XXX")
    end
  end
end
