defmodule PhoenixKitBilling.Providers.MinorUnits do
  @moduledoc """
  Converts between a shop-side `Decimal` amount (in the currency's own
  units — e.g. `Decimal.new("10.00")` for ten US dollars,
  `Decimal.new("1000")` for a thousand yen) and a payment provider's
  integer minor unit (Stripe's `amount`/`amount_cents` on a
  PaymentIntent/Refund; PayPal's amounts, once expressed the same way for
  the purpose of this conversion — see `PhoenixKitBilling.Providers.PayPal`
  for how it turns that integer into the decimal STRING its API actually
  wants).

  Every provider that previously did this multiplied or divided by a
  hard-coded `100`, which is only correct for a currency with exactly two
  decimal places. A zero-decimal currency (JPY, KRW, ...) sent through
  that factor is charged ONE HUNDRED TIMES its intended amount; a
  three-decimal one (BHD, KWD, ...) is truncated to a hundredth of a unit.
  This module replaces the literal `100` with `10^decimal_places`, read
  per-code from `phoenix_kit_currencies` (the same table and the same
  cached lookup `PhoenixKitBilling.Currency.present/3` already trusts for
  display conversion) — spec §2.6/§7 (Э5) of the per-domain-currency
  design.

  `Integer.pow/2` computes the factor — plain integer arithmetic, never a
  float, so the factor itself cannot introduce rounding error before the
  `Decimal` math even starts.

  Meant to be the ONE place this conversion happens. Two providers each
  reimplementing "amount × 100" was the original bug; two providers each
  reimplementing "amount × 10^decimal_places" would just be the same
  mistake with extra steps — the failure mode spec §12 calls "two places
  computing one price," applied to money sent over the wire instead of
  money shown on a page.
  """

  alias PhoenixKitBilling

  @doc """
  Converts `amount` to the provider's integer minor unit for `currency_code`.

  Returns `{:error, :unknown_currency}` for a code this shop's currency
  table has never heard of, rather than guessing a decimal-place count
  (2, or the base currency's own). Guessing is exactly how a misspelled or
  not-yet-seeded code (a real zero-decimal currency, typed correctly but
  looked up before it exists in the table) would silently fall back to a
  hundredths factor and charge 100x — the same bug this module exists to
  close, reintroduced at the one spot that is supposed to fail instead.
  Charging real money through an unrecognized code must refuse, not guess.

  Returns `{:error, :fractional_amount}` when `amount` carries more
  precision than the currency's `decimal_places` allows (e.g. `10.005`
  for a two-decimal currency, or any fraction at all for a zero-decimal
  one). Silently rounding it away would drop part of a charge or refund
  without the caller ever knowing; a caller that legitimately has a
  differently-rounded amount must round it itself and decide how, not
  rely on this function to guess a rounding mode.
  """
  @spec to_minor_units(Decimal.t(), String.t()) ::
          {:ok, integer()} | {:error, :unknown_currency | :fractional_amount}
  def to_minor_units(%Decimal{} = amount, currency_code) when is_binary(currency_code) do
    with {:ok, places} <- decimal_places(currency_code) do
      scaled = Decimal.mult(amount, Integer.pow(10, places))

      if Decimal.integer?(scaled) do
        {:ok, Decimal.to_integer(scaled)}
      else
        {:error, :fractional_amount}
      end
    end
  end

  @doc """
  The inverse of `to_minor_units/2`: a provider's integer minor unit back
  to the shop's `Decimal` amount, in `currency_code`'s own units.

  Division by `10^decimal_places` is always exact (it only ever removes
  trailing zeros from the minor-unit integer's decimal expansion), so this
  never rounds.
  """
  @spec from_minor_units(integer(), String.t()) ::
          {:ok, Decimal.t()} | {:error, :unknown_currency}
  def from_minor_units(minor_units, currency_code)
      when is_integer(minor_units) and is_binary(currency_code) do
    with {:ok, places} <- decimal_places(currency_code) do
      {:ok, Decimal.new(minor_units) |> Decimal.div(Integer.pow(10, places))}
    end
  end

  @doc """
  The `decimal_places` this shop's currency table has on file for
  `currency_code` — the same lookup and the same unknown-code refusal as
  `to_minor_units/2` and `from_minor_units/2`, exposed for a provider that
  needs the raw count rather than an integer minor unit (PayPal sends a
  precision-formatted decimal STRING, not an integer, so it needs to know
  how many digits belong after the point without going through the
  integer round-trip).
  """
  @spec decimal_places(String.t()) :: {:ok, non_neg_integer()} | {:error, :unknown_currency}
  def decimal_places(currency_code) when is_binary(currency_code) do
    case PhoenixKitBilling.get_currency_by_code(currency_code) do
      %{decimal_places: places} -> {:ok, places}
      nil -> {:error, :unknown_currency}
    end
  end
end
