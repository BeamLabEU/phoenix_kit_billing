defmodule PhoenixKitBilling.Test.LockWait do
  @moduledoc """
  Waits until a database backend is blocked on a lock, so a race test can say
  "the competing call is waiting" as a fact instead of guessing from a timeout
  (`Task.yield(task, 300) == nil` also passes when the call is merely slow, and
  so keeps passing when the lock it is meant to prove is gone).

  Reads `pg_stat_activity`, so it only means something outside the sandbox
  (`Sandbox.mode(Repo, :auto)`), where the holder and the waiter are separate
  connections - and it counts every backend of the test database, so use it
  while exactly one call is expected to wait.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias PhoenixKitBilling.Test.Repo

  @doc """
  Returns `:ok` once a backend waits on a lock; fails the test after about
  `attempts * 25` ms (5 s by default) with `message` when none ever does.
  """
  @spec wait_until_a_backend_waits_on_a_lock(non_neg_integer(), String.t()) :: :ok
  def wait_until_a_backend_waits_on_a_lock(
        attempts \\ 200,
        message \\ "no backend ever waited on a lock"
      ) do
    waiting =
      Repo.query!("""
      SELECT count(*) FROM pg_stat_activity
      WHERE datname = current_database() AND wait_event_type = 'Lock'
      """).rows

    cond do
      waiting != [[0]] ->
        :ok

      attempts == 0 ->
        flunk(message)

      true ->
        receive do
        after
          25 -> wait_until_a_backend_waits_on_a_lock(attempts - 1, message)
        end
    end
  end
end
