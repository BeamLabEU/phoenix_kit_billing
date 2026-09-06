defmodule PhoenixKitBilling.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Migrations

  @moduledoc """
  Pins the ownership design for `phoenix_kit_payment_provider_configs`:
  this package owns the table's FUTURE shape through its module migration
  chain, while core's V135 baseline still creates the table on every
  install and the chain's V1 merely ADOPTS it (stamps the `pkb_schema:`
  marker, changes no shape).

  No application code in this package reads or writes this table today —
  provider credentials still live in `phoenix_kit_settings`. This version
  is only the adoption step; see the moduledoc in
  `PhoenixKitBilling.Migrations`.

  Every test here is a pure data/string assertion over
  `up_statements/1`/`down_statements/2`/`up/1`/`down/1`-as-source-text and
  core's static `PhoenixKit.Migrations.ExpectedSchema.objects/1` manifest —
  none of them touch a database.
  """

  test "PhoenixKitBilling declares the module-owned migration chain" do
    # Assert the VALUE, not `function_exported?/3` — `use PhoenixKit.Module`
    # injects an overridable default `migration_module/0`, so exportedness
    # says nothing about whether this module declares one.
    assert Code.ensure_loaded?(PhoenixKitBilling)

    assert PhoenixKitBilling.migration_module() == Migrations,
           """
           PhoenixKitBilling no longer declares its migration chain \
           (migration_module/0 returned #{inspect(PhoenixKitBilling.migration_module())}).

           The chain is how phoenix_kit_payment_provider_configs's future shape
           is versioned (pkb_schema marker) and how `mix phoenix_kit.update`
           migrates hosts.
           """
  end

  describe "the coordinator implements the protocol" do
    test "current_version/0 and version_table/0" do
      assert Migrations.current_version() == 3
      assert Migrations.version_table() == "phoenix_kit_payment_provider_configs"
    end

    test "rejects a prefix that cannot be safely interpolated into DDL" do
      for bad <- ["public.\"; DROP TABLE x; --", "1st", "a-b", ""] do
        assert_raise ArgumentError, fn -> Migrations.up_statements(bad) end
        assert_raise ArgumentError, fn -> Migrations.down_statements(bad, 0) end
      end
    end
  end

  describe "the chain DDL adopts core's V135 shape" do
    test "V1 uses core's exact object names (shape-identical adoption)" do
      statements = Enum.join(Migrations.up_statements(), "\n")

      for name <- [
            "phoenix_kit_payment_provider_configs_pkey",
            "phoenix_kit_payment_provider_configs_provider_uidx",
            "phoenix_kit_payment_provider_configs_uuid_idx"
          ] do
        assert statements =~ name,
               "V1 no longer creates #{name} — it must stay shape-identical to core's V135"
      end
    end

    test "up stamps the version marker, and stamps it last" do
      statements = Migrations.up_statements()

      assert List.last(statements) ==
               "COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS 'pkb_schema:3'",
             "the marker must be stamped after the DDL it certifies, not before"
    end

    test "every up statement is guarded (IF NOT EXISTS / DO-block idempotence)" do
      # V1 runs on installs where core's V135 already created everything, so
      # every statement must be a no-op against an object that is already
      # there.
      #
      # The set is asserted before it is iterated: filtering to the COMMENT
      # and then looping means a degraded `up_statements/1` (down to just
      # its marker) would run this loop zero times and stay green while
      # every other guard vanished. Emptiness/shrinkage of the set is
      # covered where it is reachable as a real regression — the "up/1
      # emits exactly these operations" test below compares the whole set,
      # so a disappearing statement fails there instead.
      ddl = Enum.reject(Migrations.up_statements(), &String.starts_with?(&1, "COMMENT"))

      # V2's pre-index repair is the one statement that creates nothing, so
      # `IF NOT EXISTS` does not apply to it. It is idempotent by
      # construction instead: it demotes every default row but one, so a
      # second run finds nothing left to demote. Matched narrowly — any
      # OTHER unguarded statement still fails below.
      {repairs, creates} =
        Enum.split_with(ddl, &String.starts_with?(String.trim(&1), "UPDATE "))

      for stmt <- repairs do
        assert stmt =~ ~r/SET is_default = false/,
               "the only unguarded statement V2 may emit is the default-currency " <>
                 "repair; this one writes something else:\n#{stmt}"

        assert stmt =~ "LIMIT 1",
               "the repair must leave exactly one default row, or re-running it " <>
                 "is not a no-op:\n#{stmt}"
      end

      for stmt <- creates do
        assert stmt =~ "IF NOT EXISTS",
               "statement is not idempotent against a core-created table:\n#{stmt}"
      end
    end
  end

  describe "the chain can never destroy the table" do
    # Compared against the WHOLE expected content, not scanned for a
    # forbidden substring — a substring check only sees statements the
    # builder produced, so anything appended past it (a literal
    # `execute("DROP TABLE ...")` in `up/1`) would be invisible to it. That
    # path is closed by the source-text test below, which checks what is
    # executed rather than what is built.
    #
    # This test and "no statement anywhere in the data-level chain can drop
    # the table, truncate, or delete rows" below are the two halves of one
    # guarantee, post-V2: this test pins the EXACT drop statements V2's
    # `down/1` is allowed to emit (index + two columns on
    # phoenix_kit_currencies, never the table), and the other test proves
    # nothing MORE destructive slips in anywhere — including up_statements/2
    # and every prefix/target this test does not enumerate.
    test "down/1 emits exactly the marker bookkeeping, in every target and prefix" do
      # Below V2 (target 0 or 1), down/1 also drops the V2 additions on
      # phoenix_kit_currencies; below V3 (target 0, 1 or 2) it also drops
      # the V3 additions on phoenix_kit_orders — never the
      # phoenix_kit_payment_provider_configs table (see "the chain can
      # never destroy the table" below).
      v3_drops_public = [
        "ALTER TABLE public.phoenix_kit_orders DROP COLUMN IF EXISTS base_currency",
        "ALTER TABLE public.phoenix_kit_orders DROP COLUMN IF EXISTS exchange_rate",
        "ALTER TABLE public.phoenix_kit_orders DROP COLUMN IF EXISTS base_total"
      ]

      v2_drops_public = [
        "DROP INDEX IF EXISTS public.phoenix_kit_currencies_default_uidx",
        "ALTER TABLE public.phoenix_kit_currencies DROP COLUMN IF EXISTS rounding_rule",
        "ALTER TABLE public.phoenix_kit_currencies DROP COLUMN IF EXISTS rate_updated_at"
      ]

      v3_drops_alt = [
        "ALTER TABLE billing_alt.phoenix_kit_orders DROP COLUMN IF EXISTS base_currency",
        "ALTER TABLE billing_alt.phoenix_kit_orders DROP COLUMN IF EXISTS exchange_rate",
        "ALTER TABLE billing_alt.phoenix_kit_orders DROP COLUMN IF EXISTS base_total"
      ]

      v2_drops_alt = [
        "DROP INDEX IF EXISTS billing_alt.phoenix_kit_currencies_default_uidx",
        "ALTER TABLE billing_alt.phoenix_kit_currencies DROP COLUMN IF EXISTS rounding_rule",
        "ALTER TABLE billing_alt.phoenix_kit_currencies DROP COLUMN IF EXISTS rate_updated_at"
      ]

      assert Migrations.down_statements("public", 0) ==
               v3_drops_public ++
                 v2_drops_public ++
                 ["COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS NULL"]

      assert Migrations.down_statements("public", 1) ==
               v3_drops_public ++
                 v2_drops_public ++
                 [
                   "COMMENT ON TABLE public.phoenix_kit_payment_provider_configs IS 'pkb_schema:1'"
                 ]

      assert Migrations.down_statements("billing_alt", 0) ==
               v3_drops_alt ++
                 v2_drops_alt ++
                 ["COMMENT ON TABLE billing_alt.phoenix_kit_payment_provider_configs IS NULL"]

      # target 2: below V3, so the orders columns still get dropped, but
      # the currencies index/columns (added at V2, kept at target >= 2) do not.
      assert Migrations.down_statements("billing_alt", 2) ==
               v3_drops_alt ++
                 [
                   "COMMENT ON TABLE billing_alt.phoenix_kit_payment_provider_configs IS 'pkb_schema:2'"
                 ]

      # target 3 == current_version: nothing to drop, marker only.
      assert Migrations.down_statements("billing_alt", 3) ==
               [
                 "COMMENT ON TABLE billing_alt.phoenix_kit_payment_provider_configs IS 'pkb_schema:3'"
               ]
    end

    # For `up/1` the expected content is the full set of OPERATIONS rather
    # than the full SQL text. An operation is `{verb, object}`, immune to
    # reformatting and still failing on any statement added, removed or
    # retargeted — including a destructive one, which cannot enter this set
    # without changing it.
    @up_operations [
      {"CREATE TABLE", "phoenix_kit_payment_provider_configs"},
      {"DO", "phoenix_kit_payment_provider_configs_pkey"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_payment_provider_configs_provider_uidx"},
      {"CREATE UNIQUE INDEX", "phoenix_kit_payment_provider_configs_uuid_idx"},
      {"COMMENT ON TABLE", "phoenix_kit_payment_provider_configs"}
    ]

    test "up_statements/2 at target 1 emits exactly these V1 operations and no others" do
      for prefix <- ["public", "billing_alt"] do
        actual = Enum.map(Migrations.up_statements(prefix, 1), &operation/1)

        assert Enum.sort(actual) == Enum.sort(@up_operations),
               """
               up_statements(#{inspect(prefix)}, 1) does not emit the expected set of
               operations.

               unexpected: #{inspect(Enum.sort(actual) -- Enum.sort(@up_operations))}
               missing:    #{inspect(Enum.sort(@up_operations) -- Enum.sort(actual))}

               Every statement this chain emits runs against a core-created
               table. Adding one is a chain version (V2+), not something to
               slip past this list.
               """
      end
    end

    test "no statement anywhere in the data-level chain can drop the table, truncate, or delete rows" do
      # Narrowed from a bare DROP to DROP TABLE: V2's down/1 legitimately
      # emits "DROP INDEX" and "ALTER TABLE ... DROP COLUMN" against
      # phoenix_kit_currencies (see "the chain can never destroy the table"
      # below) — what must never appear anywhere is a statement that could
      # destroy a core-created TABLE, or bulk-mutate its rows.
      forbidden = ~r/\b(DROP TABLE|TRUNCATE|DELETE)\b/i

      for prefix <- ["public", "billing_alt"] do
        for stmt <- Migrations.up_statements(prefix) do
          refute stmt =~ forbidden, "up_statements(#{inspect(prefix)}) contains: #{stmt}"
        end

        for target <- [0, 1, 2, 3] do
          for stmt <- Migrations.down_statements(prefix, target) do
            refute stmt =~ forbidden,
                   "down_statements(#{inspect(prefix)}, #{target}) contains: #{stmt}"
          end
        end
      end
    end

    # `{verb, object}` for one statement. The DO block is identified by the
    # constraint it adds, since its verb says nothing about its target.
    defp operation(statement) do
      normalized = statement |> String.replace(~r/\s+/, " ") |> String.trim()

      if String.starts_with?(normalized, "DO ") do
        [_, constraint] = Regex.run(~r/ADD CONSTRAINT (\w+)/, normalized)
        {"DO", constraint}
      else
        [_, verb, object] =
          Regex.run(
            ~r/^(CREATE UNIQUE INDEX|CREATE INDEX|CREATE TABLE|COMMENT ON TABLE|DROP TABLE|DROP INDEX|TRUNCATE|DELETE FROM|ALTER TABLE)(?: IF NOT EXISTS)? (?:\w+\.)?(\w+)/,
            normalized
          )

        {verb, object}
      end
    end
  end

  describe "what reaches the database is what the tests above inspect" do
    # The tests above read `up_statements/1` and `down_statements/2`. The
    # database gets `up/1` and `down/1`. Nothing connected the two, so a
    # literal `execute("DROP TABLE ...")` written straight into `up/1`
    # would have passed every one of them — the guard was watching the data
    # while the function did the work.
    #
    # Checked against the source text, because this suite has no repo and
    # cannot run a migration.
    @source "lib/phoenix_kit_billing/migrations.ex"

    test "neither direction executes SQL of its own" do
      source = File.read!(@source)

      refute source =~ ~r/execute\(/,
             """
             #{@source} calls execute/1 with an argument of its own.

             Every statement this chain runs must come from up_statements/1 or
             down_statements/2, because those are what the tests above compare
             against their expected content. A statement executed directly is
             invisible to all of them.
             """

      assert length(Regex.scan(~r/&execute\/1/, source)) == 2,
             "expected exactly two `&execute/1` references — one per direction — " <>
               "in #{@source}"
    end

    test "each direction executes its own builder" do
      source = File.read!(@source)

      assert source =~ ~r/up_statements\(target\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "up/1 no longer pipes up_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what the up_statements-based tests above check"

      assert source =~ ~r/down_statements\(target\)\s*\|>\s*Enum\.each\(&execute\/1\)/,
             "down/1 no longer pipes down_statements/2 into execute/1 — whatever it " <>
               "runs instead is not what `down/1 emits exactly the marker " <>
               "bookkeeping` checks"
    end

    # Scoped to the two functions' own bodies, not the whole file — the
    # moduledoc legitimately discusses "never drops the table" in prose,
    # which a whole-file, case-insensitive scan would flag as a false
    # positive on the English word rather than a SQL token.
    test "up/1 and down/1 themselves contain no DROP/TRUNCATE/DELETE token" do
      source = File.read!(@source)

      [up_body] = Regex.run(~r/def up\(.*?\n  end\n/s, source)
      [down_body] = Regex.run(~r/def down\(.*?\n  end\n/s, source)

      for {name, body} <- [{"up/1", up_body}, {"down/1", down_body}] do
        refute body =~ ~r/DROP|TRUNCATE|DELETE/i,
               "#{name}'s own body in #{@source} contains a DROP/TRUNCATE/DELETE token"
      end
    end
  end

  describe "V1 stays aligned with core's manifest (while core audits the table)" do
    alias PhoenixKit.Migrations.ExpectedSchema

    # Core's V135 baseline still creates this table and core's
    # ExpectedSchema audits that shape, so until the first shape-changing
    # chain version the two DDLs must agree. This test is optional
    # documentation more than a guard against drift this package could
    # introduce (V1 has no second copy of the shape to drift from), but it
    # doubles as proof that V1 changes nothing.
    #
    # The comparison is PER FIELD and asserts both key sets match in full
    # (not just present keys) — a parse that silently dropped some of
    # core's columns, or a V1 column core does not declare, must fail
    # here rather than be skipped.
    test "every column core declares matches V1's, in full" do
      core = core_columns()
      ours = v1_columns()

      assert Map.keys(ours) -- Map.keys(core) == [],
             "V1 creates columns core's manifest does not declare: " <>
               inspect(Map.keys(ours) -- Map.keys(core))

      assert Map.keys(core) -- Map.keys(ours) == [],
             "V1 does not create columns core's manifest declares: " <>
               inspect(Map.keys(core) -- Map.keys(ours))

      for {column, expected} <- core do
        assert Map.fetch!(ours, column) == expected,
               """
               #{column}: V1 and core's manifest disagree on the column's shape.

               V1:              #{inspect(Map.fetch!(ours, column))}
               core's manifest: #{inspect(expected)}

               V1 is an adoption and must be shape-identical to core's
               baseline. A deliberate change is a chain version (V2+).
               """
      end
    end

    # `%{type, default, not_null}` per column, from the newest revision.
    defp core_columns do
      ExpectedSchema.objects("public")
      |> Enum.filter(
        &(&1.class == :column and
            String.starts_with?(&1.id, "column:phoenix_kit_payment_provider_configs."))
      )
      |> Map.new(fn object ->
        {_version, shape} = List.last(object.revisions)

        {String.replace_prefix(object.id, "column:phoenix_kit_payment_provider_configs.", ""),
         %{type: shape.type, default: shape.default, not_null: shape.not_null}}
      end)
    end

    # The same shape, parsed back out of the CREATE TABLE V1 emits.
    defp v1_columns do
      [create | _] = Migrations.up_statements("public", 1)

      ~r/^\s*"(\w+)"\s+(.+?),?$/m
      |> Regex.scan(create)
      |> Map.new(fn [_line, name, definition] -> {name, parse_column(definition)} end)
    end

    defp parse_column(definition) do
      {definition, not_null} =
        case String.replace_suffix(definition, " NOT NULL", "") do
          ^definition -> {definition, false}
          trimmed -> {trimmed, true}
        end

      case String.split(definition, " DEFAULT ", parts: 2) do
        [type] -> %{type: type, default: nil, not_null: not_null}
        [type, default] -> %{type: type, default: default, not_null: not_null}
      end
    end
  end

  describe "V2 — currencies: default uniqueness + rounding/rate columns" do
    test "up_statements/2 at target 2 adds the partial unique index and both columns" do
      stmts = Migrations.up_statements("public", 2)

      assert Enum.any?(
               stmts,
               &(&1 =~
                   ~r/CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_currencies_default_uidx ON public\.phoenix_kit_currencies USING btree \(is_default\) WHERE is_default/)
             )

      assert Enum.any?(
               stmts,
               &(&1 =~
                   ~r/ADD COLUMN IF NOT EXISTS rounding_rule character varying\(16\) DEFAULT 'exact' NOT NULL/)
             )

      assert Enum.any?(
               stmts,
               &(&1 =~ ~r/ADD COLUMN IF NOT EXISTS rate_updated_at timestamp with time zone/)
             )

      assert List.last(stmts) =~ "pkb_schema:2"
    end

    test "up_statements/2 at target 1 is the V1 adoption only" do
      stmts = Migrations.up_statements("public", 1)
      refute Enum.any?(stmts, &(&1 =~ "phoenix_kit_currencies"))
      assert List.last(stmts) =~ "pkb_schema:1"
    end

    test "V2 demotes surplus default rows BEFORE creating the unique index" do
      stmts = Migrations.up_statements("public", 2)

      demote =
        Enum.find_index(
          stmts,
          &(&1 =~ ~r/UPDATE public\.phoenix_kit_currencies SET is_default = false/)
        )

      index =
        Enum.find_index(
          stmts,
          &(&1 =~ "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_currencies_default_uidx")
        )

      assert demote,
             "V2 must repair a table that already holds two default rows — " <>
               "CREATE UNIQUE INDEX aborts on exactly the databases this index " <>
               "exists to protect"

      assert demote < index, "the demotion must run before the index is created"

      # It keeps one default rather than clearing them all: a table with no
      # default row makes `get_default_currency/0` return nil everywhere.
      demote_stmt = Enum.at(stmts, demote)
      assert demote_stmt =~ "LIMIT 1"
      assert demote_stmt =~ "uuid <> ("
      refute demote_stmt =~ ~r/\bDELETE\b/i
    end

    test "the changeset declares the constraint under the exact name V2 creates" do
      # Two lists that must stay in sync: the DDL index name and the
      # `unique_constraint/3` name in `Currency.changeset/2`. If they drift,
      # a second default row raises Ecto.ConstraintError instead of
      # returning {:error, changeset}.
      declared =
        %PhoenixKitBilling.Currency{}
        |> PhoenixKitBilling.Currency.changeset(%{})
        |> Map.fetch!(:constraints)
        |> Enum.map(& &1.constraint)

      assert "phoenix_kit_currencies_default_uidx" in declared

      assert Enum.any?(
               Migrations.up_statements("public", 2),
               &(&1 =~ "phoenix_kit_currencies_default_uidx")
             )
    end

    test "down_statements/2 to 1 drops the index and both columns, never the table" do
      stmts = Migrations.down_statements("public", 1)

      assert Enum.any?(
               stmts,
               &(&1 =~ "DROP INDEX IF EXISTS public.phoenix_kit_currencies_default_uidx")
             )

      assert Enum.any?(stmts, &(&1 =~ "DROP COLUMN IF EXISTS rounding_rule"))
      assert Enum.any?(stmts, &(&1 =~ "DROP COLUMN IF EXISTS rate_updated_at"))
      refute Enum.any?(stmts, &(&1 =~ ~r/DROP TABLE/i))
      assert List.last(stmts) =~ "pkb_schema:1"
    end
  end

  describe "V3 — orders: frozen base_currency/exchange_rate/base_total columns" do
    test "up_statements/2 at target 3 adds all three columns, with core's own future types" do
      stmts = Migrations.up_statements("public", 3)

      assert Enum.any?(
               stmts,
               &(&1 ==
                   "ALTER TABLE public.phoenix_kit_orders ADD COLUMN IF NOT EXISTS base_currency character varying(3)")
             )

      assert Enum.any?(
               stmts,
               &(&1 ==
                   "ALTER TABLE public.phoenix_kit_orders ADD COLUMN IF NOT EXISTS exchange_rate numeric(15,6)")
             )

      assert Enum.any?(
               stmts,
               &(&1 ==
                   "ALTER TABLE public.phoenix_kit_orders ADD COLUMN IF NOT EXISTS base_total numeric(15,2)")
             )

      assert List.last(stmts) =~ "pkb_schema:3"
    end

    test "up_statements/2 at target 2 does not touch phoenix_kit_orders" do
      stmts = Migrations.up_statements("public", 2)
      refute Enum.any?(stmts, &(&1 =~ "phoenix_kit_orders"))
      assert List.last(stmts) =~ "pkb_schema:2"
    end

    test "down_statements/2 to 2 drops all three columns, never the table" do
      stmts = Migrations.down_statements("public", 2)

      assert Enum.any?(
               stmts,
               &(&1 == "ALTER TABLE public.phoenix_kit_orders DROP COLUMN IF EXISTS base_currency")
             )

      assert Enum.any?(
               stmts,
               &(&1 == "ALTER TABLE public.phoenix_kit_orders DROP COLUMN IF EXISTS exchange_rate")
             )

      assert Enum.any?(
               stmts,
               &(&1 == "ALTER TABLE public.phoenix_kit_orders DROP COLUMN IF EXISTS base_total")
             )

      refute Enum.any?(stmts, &(&1 =~ ~r/DROP TABLE/i))
      assert List.last(stmts) =~ "pkb_schema:2"
    end

    test "the columns match PhoenixKitBilling.Order's own field types" do
      # Two lists that must stay in sync: the DDL and the schema's `field/2`
      # declarations. A drift here means `Order.changeset/2` casts a shape
      # the database cannot store (or vice versa) without any test noticing
      # until a real insert fails.
      alias PhoenixKitBilling.Order

      fields = Order.__schema__(:fields)
      assert :base_currency in fields
      assert :exchange_rate in fields
      assert :base_total in fields

      assert Order.__schema__(:type, :base_currency) == :string
      assert Order.__schema__(:type, :exchange_rate) == :decimal
      assert Order.__schema__(:type, :base_total) == :decimal
    end
  end
end
