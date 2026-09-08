defmodule PhoenixKitBilling.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_billing` — the
  decentralized-migrations protocol that core's `mix phoenix_kit.update`
  discovers via `migration_module/0`: `current_version/0` +
  `migrated_version_runtime/1` + idempotent `up/1` + version-aware
  `down/1`. `phoenix_kit_legal` (over `phoenix_kit_consent_logs`) is the
  closest sibling example of this exact situation — a core-created table
  whose future shape a module chain adopts.

  ## Ownership situation — read before touching

  `phoenix_kit_payment_provider_configs` is one of core's V135 baseline
  tables. Nothing in this package's `lib/` reads or writes it today — it
  is currently orphaned application-code-wise, though core still creates
  it (and can still roll it back on its own baseline `down`). Payment
  provider credentials this package actually reads and writes today live
  in `phoenix_kit_settings`, via `PhoenixKitBilling.Providers` — this
  version changes NONE of that.

  V1 is purely an ADOPTION step:

    * on existing installs the table is already there (core V135), the
      `CREATE TABLE IF NOT EXISTS` finds it, and the only new object is
      the `pkb_schema:1` marker — from then on this chain owns the
      table's future shape;
    * on a hypothetical future install whose core baseline no longer
      creates the table, the same statements create it — shape-identical
      to core's V135, with core's exact index and constraint names.

  Because V1 changes no shape, core's `ExpectedSchema` manifest (which
  still audits the V135 shape of this table) stays accurate and NO core
  release is required for this version.

  ## What `down/1` is NOT

  `down/1` unstamps the version marker; it NEVER drops
  `phoenix_kit_payment_provider_configs`. The table is core-created, and
  rolling back this module's chain must not destroy it — only core's own
  baseline rollback does that. The same invariant holds for V2 below —
  `down/1` never drops a core-created table, even one whose shape this
  chain now owns.

  The migrated version is tracked as a `pkb_schema:<N>` COMMENT on
  `phoenix_kit_payment_provider_configs` (the marker convention from the
  projects/legal chains, namespaced). A marker-less table reads as
  version 0 — the core-baseline shape before this chain existed.

  ## V2 — `phoenix_kit_currencies` gets a shape

  `phoenix_kit_currencies` is likewise a core-created table (V31
  baseline), and likewise untouched by V1 above (an unrelated table). V2
  is this chain's first shape-CHANGING step, entirely on
  `phoenix_kit_currencies`:

    * a partial unique index `phoenix_kit_currencies_default_uidx` on
      `(is_default) WHERE is_default` — today uniqueness of the default
      currency is held only by the transaction in
      `set_default_currency/1`, not by the database: two
      `is_default = true` rows raise `Ecto.MultipleResultsError` out of
      `get_default_currency/0` (`Ecto.Repo.one/2`). This index is also a
      prerequisite for a `LIMIT`-less `WHERE is_default` backfill a future
      chain runs against this table, so it must exist before that
      backfill runs, not merely by the time it finishes.
      A host can already BE in the two-default state the index forbids, so
      V2 demotes every default but one (lowest `sort_order`, then oldest)
      immediately before creating the index — otherwise `CREATE UNIQUE
      INDEX` aborts the whole chain on exactly those databases. That
      `UPDATE` is the one row-level write this chain makes to a
      core-created table, and it only repairs a state no reader can
      handle: `get_default_currency/0` raises on it today.
    * `rounding_rule character varying(16) NOT NULL DEFAULT 'exact'` and
      `rate_updated_at timestamp with time zone` — both additions with no
      reader anywhere in this version; the default reproduces today's
      rounding behavior exactly, so nothing observable changes for any
      host that migrates to V2.

  Both ride in the same chain version because this chain moves one
  version per module per release, not one version per column. `down/1`
  to below V2 drops the index and both columns — never the table.

  ## V3 — `phoenix_kit_orders` gets its frozen-currency columns

  `phoenix_kit_orders` is another core-created table this chain does not
  otherwise own. `PhoenixKitBilling.Order` (§4.5/§9.1 of the per-domain-
  currency spec) declares `base_currency`, `exchange_rate` and
  `base_total` — the shop's base currency and the rate an order was
  actually priced at, frozen at creation — but the core release that was
  originally meant to add these columns (an unreleased "V186", adding the
  identical three columns with the identical types) had not shipped to
  Hex when the schema change did. Any host resolving the currently
  published core got an `Order` struct whose SELECT lists columns the
  database does not have, and `Ecto.Repo.all/2`/`get/2`/`one/2` on
  `Order` — hit by `list_orders/1`, `get_order/1`, the user dashboard's
  orders LiveView, `delete_order/1` — all raised
  `Postgrex.Error (undefined_column)` instead of returning data.

  V3 closes that gap the same way V2 closed one on `phoenix_kit_currencies`:
  this chain adds the columns itself rather than waiting on a core
  release. The three `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` statements
  use the exact names and types core's own eventual migration does, so
  the day that core release ships, its `ADD COLUMN IF NOT EXISTS` finds
  the columns already here and no-ops — and its backfill (deriving
  `base_currency`/`exchange_rate`/`base_total` for pre-existing rows from
  `phoenix_kit_currencies`) still runs and still does useful work,
  because V3 deliberately adds the columns nullable with NO backfill of
  its own: inventing a derivation here would duplicate — and risk
  disagreeing with — logic that belongs to whichever release actually
  owns getting it right. Every reader of these three fields already
  treats `nil` as "unknown", per `Order`'s own moduledoc, so an
  unbackfilled column breaks nothing between V3 and that release.

  `down/1` to below V3 drops the three columns — never the table, same
  invariant as V1/V2.
  """

  use Ecto.Migration

  @current_version 3
  @marker_prefix "pkb_schema:"
  @version_table "phoenix_kit_payment_provider_configs"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pkb_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pkb_schema:<N>` marker when present; a marker-less or
  foreign-comment table reads as `0` (core-baseline shape — V1 is purely
  adoptive, there is no pre-chain content to defend).
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    # classoid anchors the description join to pg_class (the projects/
    # legal chains' convention).
    query = """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix]) do
      {:ok, %{rows: [[@marker_prefix <> n]]}} -> parse_version(n)
      _ -> 0
    end
  rescue
    # An invalid prefix must surface as the validation error, not be
    # swallowed into 0 ("not installed") — that misleads the operator AND
    # lets the unvalidated string reach interpolated SQL in callers'
    # fallback paths.
    e in ArgumentError ->
      reraise e, __STACKTRACE__

    _ ->
      0
  end

  @doc "Applies every chain version up to `target` (`:version` in `opts`, default `current_version/0`); idempotent."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)
    target = target_version(opts, @current_version)

    prefix
    |> up_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops the table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = target_version(opts, 0)

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. The
  ownership test parses these statements to prove that the object names
  are core's V135 names, that the CREATE TABLE stays shape-identical to
  core's `ExpectedSchema` manifest, and that nothing here can drop the
  table.

  `target` selects how much of the chain to emit (default
  `current_version/0`): `0` applies nothing (not an operation — clearing
  the marker is `down/1`'s job); `1` is the pure V135-adoption step on
  `phoenix_kit_payment_provider_configs`; `2` additionally shapes
  `phoenix_kit_currencies` (partial unique default-currency index,
  `rounding_rule`, `rate_updated_at`); `3` additionally adds
  `phoenix_kit_orders`' frozen-currency columns (see the moduledoc).
  """
  @spec up_statements(String.t(), non_neg_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target == 0 do
      # "Apply up to version 0" is not an operation: there is nothing to
      # apply, and stamping `pkb_schema:0` would be the only statement in
      # this function that assumes the marker-carrying table already
      # exists. Clearing the marker is `down/1`'s job.
      []
    else
      v1 = [
        """
        CREATE TABLE IF NOT EXISTS #{p}#{@version_table} (
          "provider" character varying(20) NOT NULL,
          "enabled" boolean DEFAULT false NOT NULL,
          "mode" character varying(10) DEFAULT 'test'::character varying NOT NULL,
          "api_key" text,
          "api_secret" text,
          "webhook_secret" text,
          "webhook_url" character varying(255),
          "last_verified_at" timestamp with time zone,
          "verification_status" character varying(20) DEFAULT 'pending'::character varying,
          "verification_error" text,
          "config" jsonb DEFAULT '{}'::jsonb NOT NULL,
          "inserted_at" timestamp with time zone NOT NULL,
          "updated_at" timestamp with time zone NOT NULL,
          "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL
        )
        """,
        """
        DO $$
        BEGIN
          IF NOT EXISTS (
            SELECT 1
            FROM pg_constraint c
            JOIN pg_class t ON t.oid = c.conrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE c.conname = '#{@version_table}_pkey'
              AND t.relname = '#{@version_table}'
              AND n.nspname = '#{prefix}'
          ) THEN
            ALTER TABLE #{p}#{@version_table} ADD CONSTRAINT #{@version_table}_pkey PRIMARY KEY (uuid);
          END IF;
        END
        $$
        """,
        "CREATE UNIQUE INDEX IF NOT EXISTS #{@version_table}_provider_uidx ON #{p}#{@version_table} USING btree (provider)",
        "CREATE UNIQUE INDEX IF NOT EXISTS #{@version_table}_uuid_idx ON #{p}#{@version_table} USING btree (uuid)"
      ]

      v2 =
        if target >= 2 do
          [
            # The index below is created on a table that is ALREADY allowed
            # to hold two `is_default` rows — that is the very defect V2
            # exists to close, and `create_currency/1` / `update_currency/2`
            # can still produce it today. `CREATE UNIQUE INDEX` on such a
            # table aborts with a unique violation, so the migration would
            # fail on precisely the databases that need it. Demote every
            # default but one (lowest `sort_order`, then oldest) first. A
            # table with zero or one default row is untouched: the subselect
            # is NULL and `uuid <> NULL` matches nothing.
            """
            UPDATE #{p}phoenix_kit_currencies SET is_default = false
            WHERE is_default
              AND uuid <> (
                SELECT uuid FROM #{p}phoenix_kit_currencies
                WHERE is_default
                ORDER BY sort_order, inserted_at, uuid
                LIMIT 1
              )
            """,
            # §9.1/§3.2 of the currency design spec: the index must exist
            # before the core backfill that assumes a single `is_default`
            # row runs — billing (this chain) migrates before core in the
            # documented release order.
            "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_currencies_default_uidx ON #{p}phoenix_kit_currencies USING btree (is_default) WHERE is_default",
            "ALTER TABLE #{p}phoenix_kit_currencies ADD COLUMN IF NOT EXISTS rounding_rule character varying(16) DEFAULT 'exact' NOT NULL",
            "ALTER TABLE #{p}phoenix_kit_currencies ADD COLUMN IF NOT EXISTS rate_updated_at timestamp with time zone"
          ]
        else
          []
        end

      v3 =
        if target >= 3 do
          [
            "ALTER TABLE #{p}phoenix_kit_orders ADD COLUMN IF NOT EXISTS base_currency character varying(3)",
            "ALTER TABLE #{p}phoenix_kit_orders ADD COLUMN IF NOT EXISTS exchange_rate numeric(15,6)",
            "ALTER TABLE #{p}phoenix_kit_orders ADD COLUMN IF NOT EXISTS base_total numeric(15,2)"
          ]
        else
          []
        end

      v1 ++ v2 ++ v3 ++ ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    end
  end

  @doc """
  The SQL `down/1` executes, as data. Below V2 this also drops the
  `phoenix_kit_currencies` index and columns V2 added, and below V3 the
  `phoenix_kit_orders` columns V3 added — never the
  `phoenix_kit_payment_provider_configs` table itself.
  """
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)

  def down_statements(prefix, target) when is_integer(target) and target >= 0 do
    validate_target!(target)
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    drop_v3 =
      if target < 3 do
        [
          "ALTER TABLE #{p}phoenix_kit_orders DROP COLUMN IF EXISTS base_currency",
          "ALTER TABLE #{p}phoenix_kit_orders DROP COLUMN IF EXISTS exchange_rate",
          "ALTER TABLE #{p}phoenix_kit_orders DROP COLUMN IF EXISTS base_total"
        ]
      else
        []
      end

    drop_v2 =
      if target < 2 do
        [
          "DROP INDEX IF EXISTS #{p}phoenix_kit_currencies_default_uidx",
          "ALTER TABLE #{p}phoenix_kit_currencies DROP COLUMN IF EXISTS rounding_rule",
          "ALTER TABLE #{p}phoenix_kit_currencies DROP COLUMN IF EXISTS rate_updated_at"
        ]
      else
        []
      end

    marker =
      if target > 0 do
        "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"
      else
        "COMMENT ON TABLE #{p}#{@version_table} IS NULL"
      end

    drop_v3 ++ drop_v2 ++ [marker]
  end

  defp parse_version(n) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  # The marker is what every later run reads to decide whether it has
  # anything to do, and nothing downstream sanity-checks the number: a
  # marker of `pkb_schema:999` makes core's `classify/2` answer
  # `:up_to_date` for every version after it, so the next real version is
  # skipped SILENTLY and forever. Applying a body while stamping a
  # version this chain does not have is therefore refused, in both
  # directions. Core's codegen always passes `current_version/0`, so this
  # only fires for a hand-written call — which is exactly the caller that
  # has no other guard.
  defp validate_target!(target) when target > @current_version do
    raise ArgumentError,
          "PhoenixKitBilling.Migrations has no version #{target} " <>
            "(current_version/0 is #{@current_version}); stamping it would make every " <>
            "later version look already applied"
  end

  defp validate_target!(_target), do: :ok

  # `:version` is read from a keyword list AND from a map, because
  # `validated_prefix/1` accepts both — and a shape it accepts must not
  # silently lose the version. Core codegens a keyword list, so the map
  # path is not exercised in production; that is exactly why it was able
  # to sit here defaulting to `@current_version` while `up/1`'s own @doc
  # promised the opposite ("a host pinned to an older chain version must
  # not silently receive a later version's adoption").
  defp target_version(opts, default) when is_list(opts) do
    Keyword.get(opts, :version, default)
  end

  defp target_version(%{} = opts, default), do: Map.get(opts, :version, default)
  defp target_version(_opts, default), do: default

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # The prefix rules are CORE's, borrowed rather than restated. This
    # chain embeds the prefix directly into index NAMES (V2's default-
    # currency index), and Postgres silently TRUNCATES an identifier past
    # 63 bytes instead of rejecting it — so a prefix core would refuse
    # produces index names that differ from core's while every command
    # still exits 0, breaking the one contract adoption rests on: core's
    # exact object names.
    # `Code.ensure_loaded?` before `function_exported?`: the latter answers
    # false for a module that simply has not been loaded yet, which under a
    # release (and in `mix run --no-start`) is the normal state — the check
    # would silently take the fallback branch and defeat its own purpose.
    helpers = PhoenixKit.Migrations.Postgres.Helpers

    if Code.ensure_loaded?(helpers) and function_exported?(helpers, :validate_prefix!, 1) do
      helpers.validate_prefix!(prefix)
    else
      # Older core without the shared validator: apply core's documented
      # rules here rather than restating a looser local copy that could
      # drift — lower-case identifiers only, capped at 20 bytes (measured
      # from the longest embedded object name, 63 - 1 - 42).
      unless is_binary(prefix) and prefix =~ ~r/^[a-z_][a-z0-9_]*$/ and byte_size(prefix) <= 20 do
        raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
      end
    end

    prefix
  end
end
