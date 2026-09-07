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

  # Deterministic on the correct pipe order: `invalidate_currency_cache/0`
  # follows its `Cache.clear/1` cast with a same-process `Cache.stats/1`
  # call, a barrier that cannot return until the cache GenServer has
  # actually applied the clear — so by the time this function's caller
  # reaches `maybe_broadcast_currencies_changed/1`, the stale entry is
  # already gone. Without that barrier this test only catches a swapped
  # pipe order intermittently (empirically ~1 run in 15), since a bare
  # `GenServer.cast` gives no cross-process ordering guarantee at all.
  test "a subscriber reacting to the event already sees the new table (cache cleared before broadcast)",
       %{eur: eur} do
    parent = self()

    # Prime the cache with the OLD rate first — otherwise this test can't
    # tell "cleared before broadcast" from the swapped order at all: with
    # nothing cached yet, the very first read after the write always goes
    # to the database regardless of pipe order.
    assert Decimal.equal?(
             PhoenixKitBilling.get_currency_by_code("EUR").exchange_rate,
             Decimal.new("0.909091")
           )

    # DataCase's shared sandbox (async: false) lets the spawned process query
    # without an explicit `Sandbox.allow/3`.
    _subscriber =
      spawn_link(fn ->
        :ok = Events.subscribe_currencies()
        send(parent, :subscribed)

        receive do
          {:currencies_changed, "EUR"} ->
            send(parent, {:seen, PhoenixKitBilling.get_currency_by_code("EUR").exchange_rate})
        end
      end)

    assert_receive :subscribed

    {:ok, _} = PhoenixKitBilling.update_currency(eur, %{exchange_rate: "0.95"})

    assert_receive {:seen, rate}
    assert Decimal.equal?(rate, Decimal.new("0.95"))
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
