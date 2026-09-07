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
    `"charm_90"`, `"integer"`), applied by `Currency.present/3` (§5);
    `"exact"` reproduces pre-Э2 behavior
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
    |> validate_charm_needs_two_decimals()
    |> unique_constraint(:code, name: :phoenix_kit_currencies_code_uidx)
    # Chain V2 added the partial unique index on `(is_default) WHERE
    # is_default`. Without this declaration a second `is_default: true`
    # row raises `Ecto.ConstraintError` out of `create_currency/1` /
    # `update_currency/2` instead of returning `{:error, changeset}` —
    # `set_default_currency/1` is the only path that demotes the incumbent.
    |> unique_constraint(:is_default, name: :phoenix_kit_currencies_default_uidx)
    |> upcase_code()
  end

  # §5: charm rules are defined in cents. A 0- or 3-decimal currency with
  # `charm_99` would print "X.99" against its own `decimal_places`.
  defp validate_charm_needs_two_decimals(changeset) do
    rule = get_field(changeset, :rounding_rule)
    places = get_field(changeset, :decimal_places)

    if rule in ["charm_99", "charm_90"] and places != 2 do
      add_error(changeset, :rounding_rule, "charm rules need exactly two decimal places")
    else
      changeset
    end
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
  what they typed (§5 — a `rounding_rule` only ever applies to a
  converted display amount). The same passthrough covers a `target` this call cannot
  resolve to anything but the base (`resolve_display_currency/1`'s
  fail-safe, §6.3) — the fallback has already logged its own warning by
  the time `present/3` sees it, so this function does not warn again.

  The target's `rounding_rule` (§5) is applied on BOTH paths below, to
  the raw `amount × rate` figure, exactly once — so a catalog price
  shown live and the same price frozen into a cart snapshot always
  agree (§12). It is never applied to the base currency: the
  passthrough above returns the base amount before either path is
  reached.

  `opts[:rate]` is the ONE way this function does not read
  `phoenix_kit_currencies` for the target's rate: a caller's frozen
  `exchange_rate` (a cart's, an order's), taken as-is regardless of what
  the currency table says right now (§12.2 — a snapshot rate is never
  mixed with a live one). With `:rate` given, the code is looked up ONLY
  for its `decimal_places` and `rounding_rule` (both applied on this
  frozen path too, §5) — never through `resolve_display_currency/1`,
  whose own fail-safe (§6.3) would substitute the base as target the
  moment the code is disabled or its live rate turns unusable, and this
  function would then see `target.code == base.code` and return the
  amount unconverted, silently discarding the very rate the caller
  froze it at. A frozen rate must survive the target currency being
  disabled AFTER the freeze — that is the whole reason a caller freezes
  one in the first place (found in review: an EUR cart disabled
  mid-checkout used to lose its conversion this way). Rounding still
  happens once, by the resolved decimal places and rule, same as the
  live-rate path; a code this shop's table has never heard of at all
  falls back to the base's own decimal places (or 2) and `"exact"`.
  """
  @spec present(Decimal.t() | number | String.t(), String.t() | nil, keyword) :: Decimal.t()
  def present(amount, display_code, opts \\ [])

  def present(amount, nil, _opts), do: to_decimal(amount)

  def present(amount, display_code, opts) when is_binary(display_code) do
    amount = to_decimal(amount)
    base = PhoenixKitBilling.get_base_currency()

    case Keyword.get(opts, :rate) do
      nil -> present_live(amount, display_code, base)
      rate -> present_frozen(amount, display_code, base, rate)
    end
  end

  # Live path: unchanged from before this module froze rates — resolves
  # the target fail-safe (§6.3) on every call, so a rate edit is visible
  # on the very next present/3 call (§4.2.1).
  defp present_live(amount, display_code, base) do
    target = PhoenixKitBilling.resolve_display_currency(display_code)

    if is_nil(base) or is_nil(target) or target.code == base.code do
      amount
    else
      rate = Decimal.div(target.exchange_rate, base.exchange_rate)

      amount
      |> Decimal.mult(rate)
      |> round_for_display(target.decimal_places, target.rounding_rule)
    end
  end

  # Frozen path: the caller already knows the rate — nothing here may
  # decide WHETHER to convert based on the target's current usability,
  # only what precision and rule to round with.
  defp present_frozen(amount, display_code, base, rate) do
    base_code = base && base.code

    if display_code == base_code do
      amount
    else
      {places, rule} = present_rounding(display_code, base)
      amount |> Decimal.mult(rate) |> round_for_display(places, rule)
    end
  end

  # With `:rate` the code is looked up ONLY for how to round (never through
  # `resolve_display_currency/1`, see the `present/3` doc); a code the table
  # has never heard of rounds like the base, exactly.
  defp present_rounding(code, base) do
    case PhoenixKitBilling.get_currency_by_code(code) do
      %{decimal_places: places, rounding_rule: rule} -> {places, rule}
      nil -> {(base && base.decimal_places) || 2, "exact"}
    end
  end

  @one Decimal.new("1")

  @doc """
  The ONE table of §5, applied to the RAW converted figure — so each rule
  rounds exactly once and `charm_99` can never round up (18.985 → 17.99,
  not 18.99 → 18.99):

    * `"exact"` (default, and `nil`) — `Decimal.round/2` by `decimal_places`;
    * `"charm_99"` — DOWN to the nearest X.99 (18.17 → 17.99, 22.00 → 21.99);
    * `"charm_90"` — to the NEAREST X.90 (18.17 → 17.90, 125.45 → 125.90);
    * `"integer"` — whole units, half-up, from the raw figure.

  Charm rules assume two minor-unit digits (the changeset enforces
  `decimal_places == 2` for them) and leave figures below 1.00 — and zero —
  at exact rounding: there is no X.99 below one unit, and "free" must stay
  free. Never applied to the base currency: `present/3` returns the base
  amount before reaching this function (§5 п.3).
  """
  @spec round_for_display(Decimal.t(), non_neg_integer, String.t() | nil) :: Decimal.t()
  def round_for_display(raw, _places, "integer"), do: Decimal.round(raw, 0)
  def round_for_display(raw, places, "charm_99"), do: charm(raw, places, &charm_99/1)
  def round_for_display(raw, places, "charm_90"), do: charm(raw, places, &charm_90/1)
  def round_for_display(raw, places, _exact), do: Decimal.round(raw, places)

  defp charm(raw, places, fun) do
    if Decimal.compare(raw, @one) == :lt, do: Decimal.round(raw, places), else: fun.(raw)
  end

  # floor(raw + 0.01) − 0.01: 18.17 → 17.99, 18.99 → 18.99, 19.00 → 18.99
  defp charm_99(raw) do
    raw |> Decimal.add("0.01") |> Decimal.round(0, :floor) |> Decimal.sub("0.01")
  end

  # round(raw − 0.90) + 0.90: 18.17 → 17.90, 125.45 → 125.90
  defp charm_90(raw) do
    raw |> Decimal.sub("0.90") |> Decimal.round(0, :half_up) |> Decimal.add("0.90")
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
