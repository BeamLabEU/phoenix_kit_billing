defmodule PhoenixKitBilling.Schemas.OrderFxFieldsTest do
  @moduledoc """
  `Order`'s frozen-at-creation currency fields (§4.5, §9.1): `base_currency`,
  `exchange_rate`, `base_total`. Pure changeset behavior — no database
  access needed — so this runs as a plain unit test regardless of whether
  the DataCase integration suite is available.
  """

  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias PhoenixKitBilling.Order

  test "an order carries base currency, frozen rate and base total" do
    attrs = %{
      total: "125.45",
      currency: "EUR",
      base_currency: "USD",
      exchange_rate: "0.909091",
      base_total: "138.00",
      billing_snapshot: %{"email" => "a@b.c"}
    }

    cs = Order.changeset(%Order{}, attrs)
    assert cs.valid?
    assert Decimal.equal?(get_change(cs, :exchange_rate), Decimal.new("0.909091"))
    assert get_change(cs, :base_currency) == "USD"
    assert Decimal.equal?(get_change(cs, :base_total), Decimal.new("138.00"))
  end

  test "the three fields are optional — an order with no base data is still valid" do
    attrs = %{
      total: "125.45",
      currency: "EUR",
      billing_snapshot: %{"email" => "a@b.c"}
    }

    cs = Order.changeset(%Order{}, attrs)
    assert cs.valid?
    assert get_change(cs, :base_currency) == nil
    assert get_change(cs, :exchange_rate) == nil
    assert get_change(cs, :base_total) == nil
  end

  test "base_currency must be 3 chars, same rule as currency" do
    attrs = %{
      total: "125.45",
      currency: "EUR",
      base_currency: "US",
      billing_snapshot: %{"email" => "a@b.c"}
    }

    cs = Order.changeset(%Order{}, attrs)
    refute cs.valid?
    assert %{base_currency: [_ | _]} = errors_on(cs)
  end

  # Mirrors the helper `PhoenixKitBilling.DataCase.errors_on/1` provides —
  # duplicated here (rather than pulling in the DataCase) so this stays a
  # plain, DB-independent unit test.
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
