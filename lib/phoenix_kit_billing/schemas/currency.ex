defmodule PhoenixKitBilling.Currency do
  @moduledoc """
  Currency schema for PhoenixKit Billing system.

  Manages supported currencies with exchange rates for multi-currency billing.

  ## Schema Fields

  - `code`: ISO 4217 currency code (e.g., "EUR", "USD", "GBP")
  - `name`: Full currency name (e.g., "Euro", "US Dollar")
  - `symbol`: Currency symbol (e.g., "€", "$", "£")
  - `decimal_places`: Number of decimal places (usually 2)
  - `is_default`: Whether this is the default currency
  - `enabled`: Whether currency is available for use
  - `exchange_rate`: Rate relative to base currency
  - `sort_order`: Display order in currency lists

  ## Usage Examples

      # List all enabled currencies
      currencies = PhoenixKitBilling.list_currencies()

      # Get default currency
      currency = PhoenixKitBilling.get_default_currency()

      # Format amount in currency
      PhoenixKitBilling.Currency.format_amount(99.99, currency)
      # => "€99.99"
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset
  import Ecto.Query, warn: false

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_currencies" do
    field(:code, :string)
    field(:name, :string)
    field(:symbol, :string)
    field(:decimal_places, :integer, default: 2)
    field(:is_default, :boolean, default: false)
    field(:enabled, :boolean, default: true)
    field(:exchange_rate, :decimal, default: Decimal.new("1.0"))
    field(:sort_order, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for currency creation and updates.
  """
  def changeset(currency, attrs) do
    currency
    |> cast(attrs, [
      :code,
      :name,
      :symbol,
      :decimal_places,
      :is_default,
      :enabled,
      :exchange_rate,
      :sort_order
    ])
    |> validate_required([:code, :name, :symbol])
    |> validate_length(:code, is: 3)
    |> validate_length(:symbol, min: 1, max: 5)
    |> validate_number(:decimal_places, greater_than_or_equal_to: 0, less_than_or_equal_to: 4)
    |> validate_number(:exchange_rate, greater_than: 0)
    |> unique_constraint(:code, name: :phoenix_kit_currencies_code_uidx)
    |> upcase_code()
  end

  defp upcase_code(changeset) do
    case get_change(changeset, :code) do
      nil -> changeset
      code -> put_change(changeset, :code, String.upcase(code))
    end
  end

  @doc """
  Formats an amount with currency symbol.

  ## Examples

      iex> currency = %Currency{symbol: "€", decimal_places: 2}
      iex> Currency.format_amount(Decimal.new("99.99"), currency)
      "€99.99"

      iex> Currency.format_amount(1234.5, currency)
      "€1,234.50"
  """
  def format_amount(amount, currency), do: format_amount(amount, currency, [])

  @doc """
  Formats an amount, optionally dropping a fractional part that is all zeros.

  `trim_zeros: true` renders 40.00 as "40" but leaves 40.50 as "40.50" — it drops
  the separator only when nothing is lost. It is a STOREFRONT option and must not
  be applied to invoices, receipts or credit notes, where "40.00" is the expected
  and auditable form; those keep calling `format_amount/2`.

  The switch deliberately does not live on `Currency` itself. A currency row is
  shared with the accounting documents, so a per-currency flag would restyle every
  invoice in EUR to satisfy a shop's storefront preference. It also does not live
  at the call site: the preference is shop-wide policy, and threading it by hand
  guarantees one page eventually shows 40 beside another showing 40.00.
  """
  def format_amount(amount, %__MODULE__{symbol: symbol, decimal_places: places}, opts) do
    amount
    |> to_decimal()
    |> Decimal.round(places)
    |> maybe_trim_zeros(Keyword.get(opts, :trim_zeros, false))
    |> format_with_thousands()
    |> then(&"#{symbol}#{&1}")
  end

  defp maybe_trim_zeros(decimal, false), do: decimal

  defp maybe_trim_zeros(decimal, true) do
    rounded = Decimal.round(decimal, 0)
    if Decimal.equal?(decimal, rounded), do: rounded, else: decimal
  end

  @doc """
  Formats an amount without currency symbol.
  """
  def format_amount_plain(amount, %__MODULE__{decimal_places: places}) do
    amount
    |> to_decimal()
    |> Decimal.round(places)
    |> format_with_thousands()
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_number(n), do: Decimal.from_float(n * 1.0)
  defp to_decimal(s) when is_binary(s), do: Decimal.new(s)

  defp format_with_thousands(decimal) do
    decimal
    |> Decimal.to_string(:normal)
    |> String.split(".")
    |> case do
      [integer] ->
        format_integer_part(integer)

      [integer, fraction] ->
        "#{format_integer_part(integer)}.#{fraction}"
    end
  end

  defp format_integer_part(str) do
    str
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  @doc """
  Converts amount from one currency to another.

  ## Examples

      iex> from = %Currency{exchange_rate: Decimal.new("1.0")}  # EUR (base)
      iex> to = %Currency{exchange_rate: Decimal.new("1.1")}    # USD
      iex> Currency.convert(100, from, to)
      Decimal.new("110.00")
  """
  def convert(amount, %__MODULE__{exchange_rate: from_rate}, %__MODULE__{exchange_rate: to_rate}) do
    amount
    |> to_decimal()
    |> Decimal.div(from_rate)
    |> Decimal.mult(to_rate)
    |> Decimal.round(2)
  end
end
