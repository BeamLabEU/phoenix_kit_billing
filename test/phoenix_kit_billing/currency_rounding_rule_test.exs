defmodule PhoenixKitBilling.CurrencyRoundingRuleTest do
  @moduledoc """
  §5: a currency's `rounding_rule` is applied INSIDE `Currency.present/3`
  (so catalog display and cart snapshot agree, §12), never to the base
  currency, and `charm_99` rounds DOWN.
  """
  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling.Currency

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(Currency)

    {:ok, _} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    {:ok, _} =
      PhoenixKitBilling.create_currency(%{
        code: "JPY",
        name: "Yen",
        symbol: "¥",
        decimal_places: 0,
        exchange_rate: "150.0"
      })

    on_exit(fn -> Currency.put_request_currency(nil) end)
    :ok
  end

  defp set_rule(code, rule) do
    {:ok, _} =
      PhoenixKitBilling.update_currency(PhoenixKitBilling.get_currency_by_code(code), %{
        rounding_rule: rule
      })
  end

  defp eq(a, b), do: Decimal.equal?(a, Decimal.new(b))

  test "exact is the default and reproduces Э1 numbers" do
    assert eq(Currency.present(Decimal.new("138.00"), "EUR"), "125.45")
    assert eq(Currency.present(Decimal.new("19.99"), "EUR"), "18.17")
  end

  test "charm_99 rounds DOWN to X.99 on both the live and the frozen path (§5 п.1, п.2)" do
    set_rule("EUR", "charm_99")
    assert eq(Currency.present(Decimal.new("19.99"), "EUR"), "17.99")
    assert eq(Currency.present(Decimal.new("138.00"), "EUR"), "124.99")

    assert eq(
             Currency.present(Decimal.new("138.00"), "EUR", rate: Decimal.new("0.909091")),
             "124.99"
           )

    assert eq(Currency.present(Decimal.new("20.89"), "EUR"), "18.99")
    assert eq(Currency.present(Decimal.new("22.00"), "EUR", rate: Decimal.new("1.0")), "21.99")
  end

  test "charm_99 never rounds UP from the raw figure (18.985 → 17.99, not 18.99)" do
    set_rule("EUR", "charm_99")
    assert eq(Currency.present(Decimal.new("18.985"), "EUR", rate: Decimal.new("1.0")), "17.99")
  end

  test "charm_90 rounds to the NEAREST X.90" do
    set_rule("EUR", "charm_90")
    assert eq(Currency.present(Decimal.new("19.99"), "EUR"), "17.90")
    assert eq(Currency.present(Decimal.new("138.00"), "EUR"), "125.90")
  end

  test "integer rounds once, from the raw figure, to whole units" do
    set_rule("EUR", "integer")
    assert eq(Currency.present(Decimal.new("19.99"), "EUR"), "18")
    assert eq(Currency.present(Decimal.new("138.00"), "EUR"), "125")
    assert eq(Currency.present(Decimal.new("18.495"), "EUR", rate: Decimal.new("1.0")), "18")
  end

  test "amounts below 1.00 and zero keep exact rounding under charm rules" do
    set_rule("EUR", "charm_99")
    assert eq(Currency.present(Decimal.new("0.55"), "EUR"), "0.50")
    assert eq(Currency.present(Decimal.new("0"), "EUR"), "0.00")
  end

  test "the base currency is never rounded by a rule (§5 п.3)" do
    set_rule("USD", "charm_99")
    assert eq(Currency.present(Decimal.new("138.00"), "USD"), "138.00")
    assert eq(Currency.present(Decimal.new("138.00"), nil), "138.00")
    assert eq(Currency.present(Decimal.new("138.00"), "USD", rate: Decimal.new("1.0")), "138.00")
  end

  test "catalog display equals the cart snapshot under charm_99 (§12)" do
    set_rule("EUR", "charm_99")
    usd = PhoenixKitBilling.get_currency_by_code("USD")
    eur = PhoenixKitBilling.get_currency_by_code("EUR")
    rate = Currency.effective_rate(eur, usd)

    for price <- ~w(138.00 19.99 7.50 1.00 0.99 249.95) do
      assert Decimal.equal?(
               Currency.present(Decimal.new(price), "EUR"),
               Currency.present(Decimal.new(price), "EUR", rate: rate)
             ),
             "display and snapshot differ for #{price}"
    end
  end

  test "round_for_display/3 is the one table of §5" do
    assert eq(Currency.round_for_display(Decimal.new("18.174"), 2, "exact"), "18.17")
    assert eq(Currency.round_for_display(Decimal.new("18.174"), 2, "charm_99"), "17.99")
    assert eq(Currency.round_for_display(Decimal.new("18.174"), 2, "charm_90"), "17.90")
    assert eq(Currency.round_for_display(Decimal.new("18.174"), 2, "integer"), "18")
    assert eq(Currency.round_for_display(Decimal.new("18.174"), 2, nil), "18.17")
    assert eq(Currency.round_for_display(Decimal.new("2999.4"), 0, "exact"), "2999")
  end

  test "changeset rejects charm rules on a currency without exactly two decimal places" do
    jpy = PhoenixKitBilling.get_currency_by_code("JPY")

    assert {:error, changeset} =
             PhoenixKitBilling.update_currency(jpy, %{rounding_rule: "charm_99"})

    assert %{rounding_rule: [_]} = errors_on(changeset)
    assert {:ok, _} = PhoenixKitBilling.update_currency(jpy, %{rounding_rule: "integer"})
  end
end
