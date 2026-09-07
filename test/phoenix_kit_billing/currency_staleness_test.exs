defmodule PhoenixKitBilling.CurrencyStalenessTest do
  @moduledoc """
  §6.2: a stale exchange rate must not stop selling. `present/3` keeps
  converting at the stale rate on its live path, but the admin needs to
  know — this covers the `fx_rate_max_age_days` threshold setting,
  `Currency.stale?/2`, `PhoenixKitBilling.currencies_with_stale_rates/0`,
  and the ONE warning the live conversion path logs per process per code.
  """
  use PhoenixKitBilling.DataCase, async: false

  import ExUnit.CaptureLog

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

    %{usd: usd, eur: eur}
  end

  defp backdate(code, days) do
    stale_at =
      DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

    Repo.update_all(Ecto.Query.from(c in Currency, where: c.code == ^code),
      set: [rate_updated_at: stale_at]
    )

    PhoenixKit.Cache.clear(:billing_currencies)
    stale_at
  end

  describe "fx_rate_max_age_days/0" do
    test "defaults to 30" do
      assert PhoenixKitBilling.fx_rate_max_age_days() == 30
    end

    test "garbage reads as the default" do
      PhoenixKit.Settings.update_setting("fx_rate_max_age_days", "soon")
      assert PhoenixKitBilling.fx_rate_max_age_days() == 30
    end

    test "zero reads as the default" do
      PhoenixKit.Settings.update_setting("fx_rate_max_age_days", "0")
      assert PhoenixKitBilling.fx_rate_max_age_days() == 30
    end

    test "honours a valid configured value" do
      PhoenixKit.Settings.update_setting("fx_rate_max_age_days", "7")
      assert PhoenixKitBilling.fx_rate_max_age_days() == 7
    end
  end

  describe "Currency.stale?/2" do
    test "the base currency is never stale, no matter its age" do
      backdate("USD", 400)
      usd = PhoenixKitBilling.get_currency_by_code("USD")
      refute Currency.stale?(usd, 1)
    end

    test "a nil rate_updated_at is not staleness" do
      Repo.update_all(Ecto.Query.from(c in Currency, where: c.code == "EUR"),
        set: [rate_updated_at: nil]
      )

      eur = PhoenixKitBilling.get_currency_by_code("EUR")
      refute Currency.stale?(eur, 30)
    end

    test "aged past the threshold is stale" do
      backdate("EUR", 40)
      eur = PhoenixKitBilling.get_currency_by_code("EUR")
      assert Currency.stale?(eur, 30)
    end

    test "aged within the threshold is not stale" do
      backdate("EUR", 10)
      eur = PhoenixKitBilling.get_currency_by_code("EUR")
      refute Currency.stale?(eur, 30)
    end
  end

  describe "currencies_with_stale_rates/0" do
    test "lists currencies aged past the configured threshold" do
      PhoenixKit.Settings.update_setting("fx_rate_max_age_days", "30")
      backdate("EUR", 40)

      assert [%{code: "EUR"}] = PhoenixKitBilling.currencies_with_stale_rates()
    end

    test "excludes currencies aged within the threshold" do
      PhoenixKit.Settings.update_setting("fx_rate_max_age_days", "30")
      backdate("EUR", 10)

      assert PhoenixKitBilling.currencies_with_stale_rates() == []
    end
  end

  describe "present/3 on a stale rate" do
    test "still converts at the stale rate and warns exactly once across three calls" do
      PhoenixKit.Settings.update_setting("fx_rate_max_age_days", "30")
      backdate("EUR", 40)

      {results, log} =
        with_log(fn ->
          for _ <- 1..3, do: Currency.present(100, "EUR")
        end)

      assert results |> Enum.uniq_by(&Decimal.to_string/1) |> length() == 1
      assert length(Regex.scan(~r/EUR/, log)) == 1
    end

    test "a fresh rate logs nothing" do
      log = capture_log(fn -> Currency.present(100, "EUR") end)
      assert log == ""
    end
  end
end
