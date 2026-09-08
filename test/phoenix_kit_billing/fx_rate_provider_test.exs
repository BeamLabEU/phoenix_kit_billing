defmodule PhoenixKitBilling.FxRateProviderTest do
  @moduledoc """
  §6.1: rates stay MANUAL by default; `:fx_rate_provider` is an optional
  MFA hook (`{mod, fun}`, matching the `:canonical_host_resolver` /
  `:sitemap_domains_provider` convention already accepted in this
  application) for a host that wants to plug in an automatic feed.

  `PhoenixKitBilling.refresh_rates_from_provider/1` must never write a
  partial result: every code the provider returns is validated BEFORE
  anything touches the table, and a single bad entry refuses the whole
  batch.
  """
  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.Events
  alias PhoenixKitBilling.Test.StaticFxRateProvider

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
        exchange_rate: "0.9"
      })

    {:ok, gbp} =
      PhoenixKitBilling.create_currency(%{
        code: "GBP",
        name: "Pound",
        symbol: "£",
        exchange_rate: "0.75"
      })

    on_exit(fn -> Application.delete_env(:phoenix_kit, :fx_rate_provider) end)

    %{usd: usd, eur: eur, gbp: gbp}
  end

  defp configure_provider(fun) when is_function(fun, 0) do
    Application.put_env(:phoenix_kit, :fx_rate_provider, {StaticFxRateProvider, :fetch})
    StaticFxRateProvider.set(fun)
  end

  describe "no provider configured" do
    test "returns the explicit error and writes nothing" do
      assert Application.get_env(:phoenix_kit, :fx_rate_provider) == nil
      assert PhoenixKitBilling.refresh_rates_from_provider() == {:error, :no_provider}

      assert Decimal.equal?(
               PhoenixKitBilling.get_currency_by_code("EUR").exchange_rate,
               Decimal.new("0.9")
             )
    end
  end

  describe "a valid provider" do
    test "updates the rates and stamps rate_updated_at", %{eur: eur} do
      # Compare against the BACKDATED stamp, not the original one: setup and
      # this test body both run well within the same wall-clock second, so
      # a fresh `DateTime.utc_now(:second)` stamp can equal (not exceed) the
      # original creation stamp at second precision. 40 days of backdating
      # makes ":gt" unambiguous regardless of that (see
      # `currency_rate_age_test.exs` for the same pattern).
      backdated = DateTime.add(eur.rate_updated_at, -40 * 86_400, :second)

      Repo.update_all(Ecto.Query.from(c in Currency, where: c.code == "EUR"),
        set: [rate_updated_at: backdated]
      )

      PhoenixKit.Cache.clear(:billing_currencies)

      configure_provider(fn -> %{"EUR" => "0.87", "GBP" => 0.7} end)

      assert {:ok, %{updated: updated, skipped_base: []}} =
               PhoenixKitBilling.refresh_rates_from_provider()

      assert Enum.sort(updated) == ["EUR", "GBP"]

      refreshed_eur = PhoenixKitBilling.get_currency_by_code("EUR")
      assert Decimal.equal?(refreshed_eur.exchange_rate, Decimal.new("0.87"))
      assert DateTime.compare(refreshed_eur.rate_updated_at, backdated) == :gt

      refreshed_gbp = PhoenixKitBilling.get_currency_by_code("GBP")
      assert Decimal.equal?(refreshed_gbp.exchange_rate, Decimal.new("0.7"))
    end

    test "accepts Decimal, float, integer and binary rate shapes" do
      configure_provider(fn ->
        %{"EUR" => Decimal.new("0.91"), "GBP" => 2}
      end)

      assert {:ok, %{updated: updated}} = PhoenixKitBilling.refresh_rates_from_provider()
      assert Enum.sort(updated) == ["EUR", "GBP"]

      assert Decimal.equal?(
               PhoenixKitBilling.get_currency_by_code("GBP").exchange_rate,
               Decimal.new("2")
             )
    end
  end

  describe "invalid data is refused whole" do
    test "an unknown currency code leaves the table unchanged" do
      configure_provider(fn -> %{"EUR" => "0.5", "ZZZ" => "1.5"} end)

      assert {:error, {:invalid_rates, issues}} =
               PhoenixKitBilling.refresh_rates_from_provider()

      assert Enum.any?(issues, &(&1.code == "ZZZ" and &1.reason == :unknown_currency))

      assert Decimal.equal?(
               PhoenixKitBilling.get_currency_by_code("EUR").exchange_rate,
               Decimal.new("0.9")
             )
    end

    test "a zero rate refuses the whole batch" do
      configure_provider(fn -> %{"EUR" => "0.5", "GBP" => "0"} end)

      assert {:error, {:invalid_rates, issues}} =
               PhoenixKitBilling.refresh_rates_from_provider()

      assert Enum.any?(issues, &(&1.code == "GBP" and &1.reason == :non_positive_rate))

      assert Decimal.equal?(
               PhoenixKitBilling.get_currency_by_code("EUR").exchange_rate,
               Decimal.new("0.9")
             )
    end

    test "a negative rate refuses the whole batch" do
      configure_provider(fn -> %{"EUR" => "-1.2", "GBP" => "0.7"} end)

      assert {:error, {:invalid_rates, issues}} =
               PhoenixKitBilling.refresh_rates_from_provider()

      assert Enum.any?(issues, &(&1.code == "EUR" and &1.reason == :non_positive_rate))

      assert Decimal.equal?(
               PhoenixKitBilling.get_currency_by_code("GBP").exchange_rate,
               Decimal.new("0.75")
             )
    end

    test "a non-numeric rate refuses the whole batch" do
      configure_provider(fn -> %{"EUR" => "0.5", "GBP" => "not-a-number"} end)

      assert {:error, {:invalid_rates, issues}} =
               PhoenixKitBilling.refresh_rates_from_provider()

      assert Enum.any?(issues, &(&1.code == "GBP" and &1.reason == :invalid_rate))

      assert Decimal.equal?(
               PhoenixKitBilling.get_currency_by_code("EUR").exchange_rate,
               Decimal.new("0.9")
             )
    end

    test "a non-map response is refused" do
      configure_provider(fn -> ["EUR", "0.5"] end)

      assert {:error, {:invalid_provider_response, _raw}} =
               PhoenixKitBilling.refresh_rates_from_provider()
    end

    test "a raising provider is reported, not crashed on" do
      configure_provider(fn -> raise "boom" end)

      assert {:error, {:provider_raised, "boom"}} =
               PhoenixKitBilling.refresh_rates_from_provider()
    end
  end

  describe "base currency" do
    test "a rate for the base is skipped while the others still apply" do
      configure_provider(fn -> %{"USD" => "1.3", "EUR" => "0.6"} end)

      assert {:ok, %{updated: ["EUR"], skipped_base: ["USD"]}} =
               PhoenixKitBilling.refresh_rates_from_provider()

      assert Decimal.equal?(
               PhoenixKitBilling.get_currency_by_code("USD").exchange_rate,
               Decimal.new("1.0")
             )

      assert Decimal.equal?(
               PhoenixKitBilling.get_currency_by_code("EUR").exchange_rate,
               Decimal.new("0.6")
             )
    end
  end

  describe "dry_run: true" do
    test "computes and validates without writing anything" do
      configure_provider(fn -> %{"EUR" => "0.5", "GBP" => "0.6"} end)

      assert {:ok, %{dry_run: true, would_update: would_update, skipped_base: []}} =
               PhoenixKitBilling.refresh_rates_from_provider(dry_run: true)

      assert Enum.sort(Enum.map(would_update, & &1.code)) == ["EUR", "GBP"]

      assert Decimal.equal?(
               PhoenixKitBilling.get_currency_by_code("EUR").exchange_rate,
               Decimal.new("0.9")
             )

      assert Decimal.equal?(
               PhoenixKitBilling.get_currency_by_code("GBP").exchange_rate,
               Decimal.new("0.75")
             )
    end

    test "still refuses invalid data and reports the same issues" do
      configure_provider(fn -> %{"EUR" => "0.5", "GBP" => "-1"} end)

      assert {:error, {:invalid_rates, issues}} =
               PhoenixKitBilling.refresh_rates_from_provider(dry_run: true)

      assert Enum.any?(issues, &(&1.code == "GBP"))
    end
  end

  describe "events" do
    test "fires exactly one currencies_changed broadcast per updated currency" do
      :ok = Events.subscribe_currencies()

      configure_provider(fn -> %{"EUR" => "0.5", "GBP" => "0.6"} end)

      assert {:ok, %{updated: updated}} = PhoenixKitBilling.refresh_rates_from_provider()
      assert Enum.sort(updated) == ["EUR", "GBP"]

      assert_receive {:currencies_changed, code1}
      assert_receive {:currencies_changed, code2}
      assert Enum.sort([code1, code2]) == ["EUR", "GBP"]
      refute_receive {:currencies_changed, _}, 100
    end

    test "a refused batch broadcasts nothing" do
      :ok = Events.subscribe_currencies()

      configure_provider(fn -> %{"EUR" => "0.5", "ZZZ" => "1.5"} end)

      assert {:error, _} = PhoenixKitBilling.refresh_rates_from_provider()
      refute_receive {:currencies_changed, _}, 100
    end
  end
end
