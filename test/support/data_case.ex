defmodule PhoenixKitBilling.DataCase do
  @moduledoc """
  Test case for tests that hit the database.

  Uses `PhoenixKitBilling.Test.Repo` with SQL Sandbox for per-test isolation.
  Tests using this case are tagged `:integration` and are automatically
  excluded when the database is unavailable (see `test/test_helper.exs`).

  ## Usage

      defmodule PhoenixKitBilling.Integration.SomethingTest do
        use PhoenixKitBilling.DataCase, async: true

        test "creates a record" do
          # Repo is available here; transactions are isolated.
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitBilling.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitBilling.ActivityLogAssertions
      import PhoenixKitBilling.DataCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth
  alias PhoenixKitBilling.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # Sub-permission checks resolve through the module registry, which asks
    # the module whether it is ENABLED - so the suite runs with billing on,
    # the same state every exercised path assumes in production.
    PhoenixKit.Settings.update_setting("billing_enabled", "true")

    :ok
  end

  @doc """
  Transforms changeset errors into a map of field → [message] for easy assertions.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Creates and persists a real `PhoenixKit.Users.Auth.User` via the public
  registration flow so cross-package FK constraints on
  `phoenix_kit_orders` / `phoenix_kit_invoices` / `phoenix_kit_subscriptions`
  / `phoenix_kit_transactions` are satisfied.

  Returns the inserted user. Accepts an optional attrs map (string keys),
  e.g. `%{"email" => "x@y.z"}`.
  """
  def fixture_user(attrs \\ %{}) do
    email = Map.get(attrs, "email") || "billing-#{System.unique_integer([:positive])}@example.com"

    {:ok, user} =
      Auth.register_user(%{
        "email" => email,
        "password" => "password1234567"
      })

    user
  end

  @doc """
  Lets a spawned process use the test's sandbox connection.

  Needed by tests that exercise real DB CONCURRENCY (two tasks racing for
  the same row lock) rather than simulating it.
  """
  def allow_sandbox(pid) do
    Sandbox.allow(TestRepo, self(), pid)
  end
end
