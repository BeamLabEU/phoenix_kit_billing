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
  - `rounding_rule`: Display rounding strategy (`"exact"`, `"charm_99"`,
    `"charm_90"`, `"integer"`); no reader uses this yet — `"exact"`
    reproduces today's behavior
  - `rate_updated_at`: When `exchange_rate` was last refreshed; no reader
    uses this yet

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
    field(:rounding_rule, :string, default: "exact")
    field(:rate_updated_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @rounding_rules ~w(exact charm_99 charm_90 integer)

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
      :sort_order,
      :rounding_rule,
      :rate_updated_at
    ])
    |> validate_required([:code, :name, :symbol])
    |> validate_length(:code, is: 3)
    |> validate_length(:symbol, min: 1, max: 5)
    |> validate_number(:decimal_places, greater_than_or_equal_to: 0, less_than_or_equal_to: 4)
    |> validate_number(:exchange_rate, greater_than: 0)
    |> validate_inclusion(:rounding_rule, @rounding_rules)
    |> unique_constraint(:code, name: :phoenix_kit_currencies_code_uidx)
    # Chain V2 added the partial unique index on `(is_default) WHERE
    # is_default`. Without this declaration a second `is_default: true`
    # row raises `Ecto.ConstraintError` out of `create_currency/1` /
    # `update_currency/2` instead of returning `{:error, changeset}` —
    # `set_default_currency/1` is the only path that demotes the incumbent.
    |> unique_constraint(:is_default, name: :phoenix_kit_currencies_default_uidx)
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
  def format_amount(amount, %__MODULE__{symbol: symbol, decimal_places: places}) do
    amount
    |> to_decimal()
    |> Decimal.round(places)
    |> format_with_thousands()
    |> then(&"#{symbol}#{&1}")
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

  @doc """
  The ONE place a base-currency amount becomes a display-currency amount
  (§4.3, §12 of the per-domain-currency spec). `Currency.convert/3` above
  is NOT that place — it is never called from anywhere but its own
  moduledoc example (§12.1); every other caller in this codebase must
  come through here.

  Takes a display-currency CODE, not a `%Currency{}`, and resolves both
  the base and the target through `PhoenixKitBilling.get_base_currency/0`
  and `PhoenixKitBilling.resolve_display_currency/1` on EVERY call — so
  nothing upstream can cache a `%Currency{}` (and, inside it, a rate) in
  a struct or an assign and have that rate go stale the moment an admin
  edits it (§4.2.1). A `nil` code (no display override in play) and the
  base currency's own code both return `amount` unrounded: an author's
  stored price is not "converted to itself" and then rounded away from
  what they typed (§5, exact rounding only in Э1 — no psychological
  rounding yet). The same passthrough covers a `target` this call cannot
  resolve to anything but the base (`resolve_display_currency/1`'s
  fail-safe, §6.3) — the fallback has already logged its own warning by
  the time `present/3` sees it, so this function does not warn again.

  `opts[:rate]` is the ONE way this function does not read
  `phoenix_kit_currencies` for the target's rate: the cart's frozen
  `exchange_rate`, taken as-is regardless of what the currency table
  says right now (§12.2 — a snapshot rate is never mixed with a live
  one). Rounding still happens once, by the target's `decimal_places`,
  same as the live-rate path.
  """
  @spec present(Decimal.t() | number | String.t(), String.t() | nil, keyword) :: Decimal.t()
  def present(amount, display_code, opts \\ [])

  def present(amount, nil, _opts), do: to_decimal(amount)

  def present(amount, display_code, opts) when is_binary(display_code) do
    amount = to_decimal(amount)
    base = PhoenixKitBilling.get_base_currency()
    target = PhoenixKitBilling.resolve_display_currency(display_code)

    if is_nil(base) or is_nil(target) or target.code == base.code do
      amount
    else
      rate = Keyword.get(opts, :rate) || Decimal.div(target.exchange_rate, base.exchange_rate)

      amount
      |> Decimal.mult(rate)
      |> Decimal.round(target.decimal_places)
    end
  end

  @doc """
  The multiplier `base -> target` a cart freezes at creation (§4.4): the
  target's rate over the base's rate, rounded to six decimal places —
  enough headroom that repeated freeze/thaw does not accumulate visible
  drift, matching `phoenix_kit_shop_carts.exchange_rate`'s
  `numeric(15,6)` column.
  """
  @spec effective_rate(t(), t()) :: Decimal.t()
  def effective_rate(%__MODULE__{exchange_rate: target_rate}, %__MODULE__{
        exchange_rate: base_rate
      }) do
    target_rate
    |> Decimal.div(base_rate)
    |> Decimal.round(6)
  end

  @request_currency_key :phoenix_kit_billing_request_currency

  @doc """
  Sets (or, with `nil`/`""`, clears) the request-scoped display-currency
  CODE — the currency the shopper on THIS request should see and be
  charged in, as opposed to the shop's base currency (§4.2 of the
  per-domain-currency spec: authoring/storage always stays in the base;
  only display and checkout resolve per request).

  Process-scoped, mirroring
  `PhoenixKit.Languages.put_request_default_language/1`: the host app
  (a Plug for the dead render, an `on_mount` hook for LiveView) sets it
  per request, and it does NOT propagate to spawned `Task`s or Oban jobs.
  Always call it — including with `nil` — on every request, even ones
  with no override, so a previous request's code can never leak forward
  on a reused process. `""` is treated the same as `nil` for a host that
  builds the code from a possibly-blank domain map lookup.

  Stores the CODE, never a `%Currency{}` struct (§4.2.1) — a cached
  struct across requests could go stale the moment an admin changes a
  rate, while the code is re-resolved through
  `PhoenixKitBilling.resolve_display_currency/1` on every read.
  """
  @spec put_request_currency(String.t() | nil) :: :ok
  def put_request_currency(nil) do
    Process.delete(@request_currency_key)
    :ok
  end

  def put_request_currency(""), do: put_request_currency(nil)

  def put_request_currency(code) when is_binary(code) do
    Process.put(@request_currency_key, String.upcase(code))
    :ok
  end

  @doc """
  Returns the request/process-scoped display-currency code override, if
  any set by `put_request_currency/1` on this process.
  """
  @spec get_request_currency() :: String.t() | nil
  def get_request_currency, do: Process.get(@request_currency_key)
end
