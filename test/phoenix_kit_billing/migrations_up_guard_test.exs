defmodule PhoenixKitBilling.MigrationsUpGuardTest do
  @moduledoc """
  `Migrations.up/1` leaves a database already past its target as it is.

  Ecommerce runs this chain before its own (its foreign key points at
  `phoenix_kit_payment_options`), so on a fresh install billing can be at its
  current version before the host's own, older billing migration files run.
  Those must not lower the marker. The chain runs for real, through an
  `Ecto.Migration` runner, into a scratch schema; the DDL rolls back with the
  sandbox transaction.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitBilling.Migrations

  @prefix "pkb_up_guard"

  defmodule Up do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.up(Process.get(:pkb_up_opts))
  end

  # One migration that brings billing current and then runs an older billing
  # target, as a host file holding two chain calls would. The first call's
  # statements are queued until the migration flushes them.
  defmodule CurrentThenOld do
    @moduledoc false
    use Ecto.Migration

    def up do
      prefix = Process.get(:pkb_up_opts) |> Keyword.fetch!(:prefix)
      Migrations.up(prefix: prefix)
      Migrations.up(prefix: prefix, version: 4)
    end
  end

  defp run_up(opts) do
    Process.put(:pkb_up_opts, opts)
    Runner.run(Repo, Repo.config(), 1, Up, :forward, :up, :up, log: false)
  end

  defp version, do: Migrations.migrated_version_runtime(prefix: @prefix)

  setup do
    Repo.query!("CREATE SCHEMA #{@prefix}")
    Repo.query!("CREATE TABLE #{@prefix}.phoenix_kit_users (uuid uuid PRIMARY KEY)")

    Repo.query!(
      "CREATE FUNCTION #{@prefix}.uuid_generate_v7() RETURNS uuid LANGUAGE sql AS 'SELECT public.uuid_generate_v7()'"
    )

    :ok
  end

  test "an older target does not lower the marker of a newer database" do
    run_up(prefix: @prefix)
    assert version() == Migrations.current_version()

    # What the host's billing files written for V4 and V5 do when ecommerce's
    # chain already brought billing current.
    run_up(prefix: @prefix, version: 4)
    run_up(prefix: @prefix, version: 5)

    assert version() == Migrations.current_version()
  end

  test "an older target in the same migration as a newer one does not lower the marker" do
    Process.put(:pkb_up_opts, prefix: @prefix)
    Runner.run(Repo, Repo.config(), 1, CurrentThenOld, :forward, :up, :up, log: false)

    assert version() == Migrations.current_version()
  end

  test "a target this code has no step for is refused even on a newer database" do
    run_up(prefix: @prefix)

    assert_raise ArgumentError, fn ->
      run_up(prefix: @prefix, version: Migrations.current_version() + 1)
    end
  end

  test "an older target still builds on an empty schema" do
    run_up(prefix: @prefix, version: 4)
    assert version() == 4

    run_up(prefix: @prefix)
    assert version() == Migrations.current_version()
  end
end
