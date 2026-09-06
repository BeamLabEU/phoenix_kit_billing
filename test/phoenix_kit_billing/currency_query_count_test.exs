defmodule PhoenixKitBilling.CurrencyQueryCountTest do
  @moduledoc """
  Measures how many database queries `Currency.present/3` costs per call
  (§13). Before caching, `present/3` alone makes two: `get_base_currency/0`
  and (for a non-base code) `resolve_display_currency/1`'s
  `get_currency_by_code/1` — the base is read a THIRD time inside
  `resolve_display_currency/1` itself before it compares codes, so the
  uncached cost is 3 queries per call, not 2. 50 calls therefore cost 150
  queries uncached; measured before this cache existed
  (see Э1-B5's implementation report for the exact reproduction).

  Attaches to `[:phoenix_kit_billing, :test, :repo, :query]` — the
  telemetry event `PhoenixKitBilling.Test.Repo` emits per query, confirmed
  against `test/support/test_repo.ex`'s Ecto config (no custom
  `telemetry_prefix`, so Ecto's default `[otp_app, :test, :repo, :query]`
  applies, with `otp_app: :phoenix_kit_billing`).
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling.Currency

  @telemetry_event [:phoenix_kit_billing, :test, :repo, :query]

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

    {:ok, _eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    :ok
  end

  # Counts queries emitted DURING `fun.()`, on the calling process only —
  # `Ecto.Adapters.SQL` emits its `:query` telemetry event synchronously,
  # in the process that issued the query, so a handler that just `send`s
  # to `self()` sees every count before `fun.()` returns; no sleep, no
  # race.
  defp count_queries(fun) do
    handler_id = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      handler_id,
      @telemetry_event,
      fn _event, _measurements, _metadata, _config -> send(parent, :query_emitted) end,
      nil
    )

    fun.()

    :telemetry.detach(handler_id)
    drain_query_count()
  end

  defp drain_query_count(count \\ 0) do
    receive do
      :query_emitted -> drain_query_count(count + 1)
    after
      0 -> count
    end
  end

  test "present/3 costs at most 3 queries total for 50 calls, once cached" do
    # Warm the cache first — this test measures the STEADY STATE (every
    # real page render after the first), not the one-time cold-start cost.
    Currency.present(Decimal.new("1"), "EUR")

    count = count_queries(fn -> for _ <- 1..50, do: Currency.present(Decimal.new("1"), "EUR") end)

    # Expected: 0. get_base_currency/0 and get_currency_by_code/1 are both
    # already warm from the call above, and `present/3`'s own logic makes
    # no query of its own. Asserting `<= 3` per the plan/task's own bound
    # rather than the tighter number this cache actually achieves, so a
    # future change that costs one query per call (a TTL just expired,
    # say) does not turn a real regression into a hard test failure over
    # a number more precise than the requirement.
    assert count <= 3
  end
end
