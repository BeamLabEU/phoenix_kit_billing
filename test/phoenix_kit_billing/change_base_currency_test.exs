defmodule PhoenixKitBilling.ChangeBaseCurrencyTest do
  @moduledoc """
  §4.9: changing the base currency without repricing the catalog is a
  silent re-pricing of the whole shop — `138.00` does not change, its
  MEANING does, and no database notices on its own. So `change_base_currency/2`
  is an operation, not a toggle.

  Billing owns only the two steps that touch the currency table itself
  (renormalize every rate, promote the new base at exactly 1.0); the
  catalog/shipping recompute (§4.9 steps 2-4) belongs to whichever
  package owns the catalog now (`phoenix_kit_catalogue`, not this one),
  and is injected as `opts[:reprice]` — this suite proves it runs
  exactly once, in the right order, inside the SAME transaction the
  renormalization runs in.

  The "carts and orders are never touched" describe block below tests
  billing's OWN `Order` (manual bank-transfer/invoicing) as a
  same-package proxy for that invariant — it is NOT the storefront
  cart/checkout order §4.4/§4.5 actually describe (billing has no
  "cart" concept at all; that model lives in `phoenix_kit_catalogue`,
  which this suite cannot reach). The real storefront assertion belongs
  to a later ecommerce-side repricing task.
  """
  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling.Currency

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

    {:ok, gbp} =
      PhoenixKitBilling.create_currency(%{
        code: "GBP",
        name: "Pound",
        symbol: "£",
        enabled: false,
        exchange_rate: "0.772727"
      })

    %{usd: usd, eur: eur, gbp: gbp}
  end

  describe "the happy path" do
    # Exact rounded values confirmed against Postgres's own `round/2`
    # (the same fragment the implementation uses), NOT hand-computed:
    #   select round(1.0/0.909091, 6), round(0.772727/0.909091, 6);
    #   -->  1.100000            |  0.850000
    test "switching USD -> EUR renormalizes every rate, including the disabled one" do
      assert {:ok, %{old_base: "USD", rate: rate}} =
               PhoenixKitBilling.change_base_currency("EUR", catalog_size: 0)

      assert Decimal.equal?(rate, Decimal.new("0.909091"))

      eur = PhoenixKitBilling.get_currency_by_code("EUR")
      usd = PhoenixKitBilling.get_currency_by_code("USD")
      gbp = PhoenixKitBilling.get_currency_by_code("GBP")

      assert eur.is_default
      assert Decimal.equal?(eur.exchange_rate, Decimal.new("1.0"))
      assert Decimal.equal?(usd.exchange_rate, Decimal.new("1.100000"))
      # Disabled currencies are still renormalized — step 1 has no
      # `enabled` filter, matching `set_default_currency/1`.
      assert Decimal.equal?(gbp.exchange_rate, Decimal.new("0.850000"))
      refute usd.is_default
      refute gbp.is_default
    end

    test "rate_updated_at moves on every row the operation rewrites" do
      # Back-dated deliberately: the whole operation can complete inside
      # the SAME wall-clock second the fixtures were created in (the
      # column is second-precision), which would make "moved" and
      # "didn't move" indistinguishable by plain `DateTime.compare/2`.
      # Matches the pattern already used in currency_rate_age_test.exs.
      old_at =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(Currency, set: [rate_updated_at: old_at])
      PhoenixKit.Cache.clear(:billing_currencies)

      {:ok, _} = PhoenixKitBilling.change_base_currency("EUR", catalog_size: 0)

      for code <- ["USD", "EUR", "GBP"] do
        new_at = PhoenixKitBilling.get_currency_by_code(code).rate_updated_at
        assert DateTime.compare(new_at, old_at) == :gt, "#{code} was not re-dated"
      end
    end
  end

  describe "refusals" do
    test "unknown code" do
      assert PhoenixKitBilling.change_base_currency("XXX", catalog_size: 0) ==
               {:error, :unknown_currency}
    end

    test "disabled target" do
      assert PhoenixKitBilling.change_base_currency("GBP", catalog_size: 0) ==
               {:error, :currency_not_usable}
    end

    test "zero rate" do
      {:ok, zwl} =
        PhoenixKitBilling.create_currency(%{
          code: "ZWL",
          name: "Zimbabwe Dollar",
          symbol: "Z$",
          exchange_rate: "1.5"
        })

      # The changeset itself forbids a non-positive rate — force one in
      # directly, the same way display_currency_test.exs does, to
      # reproduce a row a raw SQL UPDATE could actually produce.
      Repo.update_all(Ecto.Query.from(c in Currency, where: c.uuid == ^zwl.uuid),
        set: [exchange_rate: Decimal.new("0")]
      )

      PhoenixKit.Cache.clear(:billing_currencies)

      assert PhoenixKitBilling.change_base_currency("ZWL", catalog_size: 0) ==
               {:error, :currency_not_usable}
    end

    test "already the base" do
      assert PhoenixKitBilling.change_base_currency("USD", catalog_size: 0) ==
               {:error, :already_base}
    end

    test "non-empty catalog without :reprice refuses" do
      assert PhoenixKitBilling.change_base_currency("EUR", catalog_size: 5) ==
               {:error, :reprice_required}
    end

    test "missing :catalog_size refuses even with :reprice given" do
      assert PhoenixKitBilling.change_base_currency("EUR",
               reprice: fn _, _, _ -> {:ok, :ignored} end
             ) ==
               {:error, :catalog_size_unknown}
    end

    test "a negative :catalog_size is a caller error, not permission to skip repricing" do
      assert PhoenixKitBilling.change_base_currency("EUR", catalog_size: -1) ==
               {:error, :invalid_catalog_size}
    end
  end

  describe ":reprice" do
    test "runs exactly once, with (old_base, new_base, multiplier) in that order, after renormalization" do
      test_pid = self()

      reprice = fn old_code, new_code, multiplier ->
        # A RAW read, deliberately bypassing Billing's own cache, on the
        # SAME connection this transaction is running on — the only way
        # to prove this callback runs strictly AFTER step 1 rather than
        # merely being scheduled before commit. By this point USD's OWN
        # rate is no longer the multiplier a repricing implementation
        # would need (it now reads the reciprocal) — that is exactly why
        # `multiplier` is a passed argument, not something derived here.
        usd = Repo.get_by!(Currency, code: "USD")
        send(test_pid, {:reprice_called, old_code, new_code, multiplier, usd.exchange_rate})
        {:ok, :repriced}
      end

      assert {:ok, %{old_base: "USD", rate: rate}} =
               PhoenixKitBilling.change_base_currency("EUR", catalog_size: 1, reprice: reprice)

      assert_received {:reprice_called, "USD", "EUR", multiplier, usd_rate_seen_by_reprice}
      # The multiplier IS the `:rate` this call returns — same divisor,
      # same value, handed to the caller two ways.
      assert Decimal.equal?(multiplier, rate)
      assert Decimal.equal?(multiplier, Decimal.new("0.909091"))
      assert Decimal.equal?(usd_rate_seen_by_reprice, Decimal.new("1.100000"))
      refute_received {:reprice_called, _, _, _, _}
    end

    test "an {:error, _} from :reprice rolls back renormalization entirely — the table is byte-identical after" do
      before_state = currency_snapshot()

      assert PhoenixKitBilling.change_base_currency("EUR",
               catalog_size: 1,
               reprice: fn _old, _new, _multiplier -> {:error, :boom} end
             ) == {:error, :boom}

      assert currency_snapshot() == before_state
    end

    defp currency_snapshot do
      Currency
      |> Repo.all()
      |> Enum.map(&{&1.code, &1.exchange_rate, &1.is_default, &1.enabled, &1.rate_updated_at})
      |> Enum.sort()
    end
  end

  describe "broadcasts a currencies_changed event (§4.2.1 п.5)" do
    # Э2 subscribed every open storefront tab to this event precisely so
    # a rate edit re-renders live, no reload — a base-currency change
    # rewrites EVERY rate in the table, the largest change this module
    # can make, so it must announce too, exactly like every other
    # currency writer, or every open tab keeps showing prices computed
    # from the old base until the visitor navigates.
    setup do
      :ok = PhoenixKitBilling.Events.subscribe_currencies()
      :ok
    end

    test "a successful base change broadcasts once, naming the new base" do
      assert {:ok, %{old_base: "USD"}} =
               PhoenixKitBilling.change_base_currency("EUR", catalog_size: 0)

      assert_receive {:currencies_changed, "EUR"}
      refute_receive {:currencies_changed, _}, 100
    end

    test "a failed base change (reprice errors) broadcasts nothing" do
      assert PhoenixKitBilling.change_base_currency("EUR",
               catalog_size: 1,
               reprice: fn _old, _new, _multiplier -> {:error, :boom} end
             ) == {:error, :boom}

      refute_receive {:currencies_changed, _}, 100
    end
  end

  describe "carts and orders are never touched (§4.9 step 6)" do
    # Billing has no "cart" concept at all — carts belong entirely to
    # `phoenix_kit_catalogue`/ecommerce, which this package cannot see.
    # What billing DOES have is its own `Order` (manual bank-transfer /
    # invoicing orders, a different concept from the storefront's
    # cart/checkout order the spec's §4.4/§4.5 actually describe) — this
    # proves THAT model's frozen `currency` field survives the
    # operation untouched, as a same-package proxy for the invariant.
    # It does not cover the real storefront cart/order; see the report.
    test "a billing Order created before the switch keeps its own currency field" do
      user = fixture_user()

      {:ok, order} =
        PhoenixKitBilling.create_order(user, %{
          "total" => Decimal.new("99.00"),
          "currency" => "USD",
          "billing_snapshot" => %{"email" => "buyer@example.com"}
        })

      {:ok, _} = PhoenixKitBilling.change_base_currency("EUR", catalog_size: 0)

      reloaded = PhoenixKitBilling.get_order!(order.uuid)
      assert reloaded.currency == "USD"
      assert Decimal.equal?(reloaded.total, Decimal.new("99.00"))
    end
  end
end
