defmodule PhoenixKitBilling.CurrencyEventsTest do
  @moduledoc "Every write that can change what `present/3` returns is announced AFTER the cache is cleared (§4.2.1 п.5)."
  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling.{Currency, Events}

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(Currency)

    {:ok, usd} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    :ok = Events.subscribe_currencies()
    %{usd: usd, eur: eur}
  end

  test "update_currency/2 broadcasts after the cache is cleared", %{eur: eur} do
    {:ok, _} = PhoenixKitBilling.update_currency(eur, %{exchange_rate: "0.95"})
    assert_receive {:currencies_changed, "EUR"}

    assert Decimal.equal?(
             PhoenixKitBilling.get_currency_by_code("EUR").exchange_rate,
             Decimal.new("0.95")
           )
  end

  test "create, set_default and delete broadcast too", %{eur: eur} do
    {:ok, gbp} =
      PhoenixKitBilling.create_currency(%{
        code: "GBP",
        name: "Pound",
        symbol: "£",
        exchange_rate: "0.772727"
      })

    assert_receive {:currencies_changed, "GBP"}

    {:ok, _} = PhoenixKitBilling.set_default_currency(eur)
    assert_receive {:currencies_changed, "EUR"}

    {:ok, _} = PhoenixKitBilling.delete_currency(gbp)
    assert_receive {:currencies_changed, "GBP"}
  end

  test "a rejected write does not broadcast", %{eur: eur} do
    {:error, _} = PhoenixKitBilling.update_currency(eur, %{exchange_rate: "-1"})
    refute_receive {:currencies_changed, _}, 100
  end
end
