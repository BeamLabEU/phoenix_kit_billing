defmodule PhoenixKitBilling.Schemas.CurrencyTest do
  use PhoenixKitBilling.DataCase, async: true

  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.Test.Repo

  # NB: EUR / GBP / USD are seeded by core migration V31, so tests that
  # insert use a non-seeded code (CHF) to avoid colliding with the seed.
  @valid %{code: "chf", name: "Swiss Franc", symbol: "Fr"}

  describe "changeset/2" do
    test "is valid with required fields and upcases the code" do
      cs = Currency.changeset(%Currency{}, @valid)
      assert cs.valid?
      assert get_change(cs, :code) == "CHF"
    end

    test "requires code, name, symbol" do
      cs = Currency.changeset(%Currency{}, %{})
      errors = errors_on(cs)
      assert "can't be blank" in errors.code
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.symbol
    end

    test "code must be exactly 3 chars" do
      cs = Currency.changeset(%Currency{}, %{@valid | code: "US"})
      assert %{code: [_ | _]} = errors_on(cs)
    end

    test "symbol length is bounded 1..5" do
      cs = Currency.changeset(%Currency{}, %{@valid | symbol: "toolong"})
      assert %{symbol: [_ | _]} = errors_on(cs)
    end

    test "decimal_places must be 0..4" do
      assert %{decimal_places: [_ | _]} =
               errors_on(Currency.changeset(%Currency{}, Map.put(@valid, :decimal_places, 5)))

      assert %{decimal_places: [_ | _]} =
               errors_on(Currency.changeset(%Currency{}, Map.put(@valid, :decimal_places, -1)))
    end

    test "exchange_rate must be > 0" do
      cs = Currency.changeset(%Currency{}, Map.put(@valid, :exchange_rate, Decimal.new("0")))
      assert %{exchange_rate: [_ | _]} = errors_on(cs)
    end

    test "rounding_rule defaults to exact and rejects unknown values" do
      cs = Currency.changeset(%Currency{}, @valid)
      assert get_field(cs, :rounding_rule) == "exact"

      cs = Currency.changeset(%Currency{}, Map.put(@valid, :rounding_rule, "made_up"))
      assert %{rounding_rule: [_ | _]} = errors_on(cs)

      cs = Currency.changeset(%Currency{}, Map.put(@valid, :rounding_rule, "charm_99"))
      assert cs.valid?
    end

    test "duplicate code returns a changeset error (constraint name matches DB index)" do
      # Regression: unique_constraint(:code) now pins the real DB index name
      # `phoenix_kit_currencies_code_uidx`, so a duplicate is translated into a
      # changeset error instead of raising Ecto.ConstraintError.
      {:ok, _} = Repo.insert(Currency.changeset(%Currency{}, @valid))

      assert {:error, changeset} =
               Repo.insert(Currency.changeset(%Currency{}, %{@valid | name: "Dollar 2"}))

      assert "has already been taken" in errors_on(changeset).code
    end
  end

  describe "format_amount/2" do
    test "prefixes the symbol and rounds to decimal_places" do
      c = %Currency{symbol: "€", decimal_places: 2}
      assert Currency.format_amount(Decimal.new("99.999"), c) == "€100.00"
    end

    test "adds thousands separators" do
      c = %Currency{symbol: "$", decimal_places: 2}
      assert Currency.format_amount(Decimal.new("1234567.5"), c) == "$1,234,567.50"
    end
  end

  describe "convert/3" do
    test "converts via exchange rates" do
      from = %Currency{exchange_rate: Decimal.new("1.0")}
      to = %Currency{exchange_rate: Decimal.new("1.1")}
      assert Currency.convert(Decimal.new("100"), from, to) == Decimal.new("110.00")
    end
  end
end
