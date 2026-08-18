defmodule PhoenixKitBilling.Regression.ActivityLogFailureVisibilityTest do
  @moduledoc """
  `Activity.log/2` (`lib/phoenix_kit_billing/activity.ex`) used to rescue
  `Postgrex.Error` and `DBConnection.OwnershipError` to bare `:ok`, with
  no log line. On paper that's the same defect class as B003's email
  fallback: a real failure returning something indistinguishable from
  `PhoenixKit.Activity.log/1` genuinely succeeding.

  In practice, checked directly rather than assumed: it wasn't reachable.
  Core's own `PhoenixKit.Activity.log/1` already wraps its DB call in a
  catch-all `rescue e -> Logger.warning(...); {:error, e}`, so any
  exception raised inside it — these two included — gets caught and
  returned as an ordinary `{:error, e}` *value* one level down, before it
  would ever reach billing's own `rescue`. This test proves that: calling
  through an unowned process gets a logged, returned
  `{:error, %DBConnection.OwnershipError{}}` today, with or without the
  fix in `activity.ex` (verified by running it against both versions —
  neither failed). It's an assurance test, not a red/green regression
  test for that specific fix — there's no reachable path to make red.
  The rescue clauses were still cleaned up (collapsed into one, always
  logged) since dead code with silently different behavior than its
  neighbor is worth removing regardless, and because relying on an
  undocumented core internal (that it always rescues internally) to stay
  true forever isn't something to build on.

  `DBConnection.OwnershipError` reached this way — a process that never
  checked out or was never explicitly allowed onto the caller's DB
  connection (a background job, anything outside the request/LiveView
  process) — for real, not mocked: `async: true` puts the test repo in
  non-shared ownership mode (see `data_case.ex`:
  `Sandbox.start_owner!(TestRepo, shared: not tags[:async])`), and the
  logging call runs inside a bare `spawn/1` process — not `Task.async/1`,
  which sets `$callers` and gets auto-allowed onto the spawning
  process's sandbox connection, defeating the point of this test.
  """

  use PhoenixKitBilling.DataCase, async: true

  import ExUnit.CaptureLog

  alias PhoenixKitBilling.Activity

  test "a DB ownership failure during logging is logged and returned as a distinguishable error" do
    test_pid = self()

    log =
      capture_log(fn ->
        spawn(fn ->
          result =
            Activity.log("billing.order_created",
              actor_uuid: "01a01234-1234-7234-8234-123412341234",
              resource_type: "order",
              resource_uuid: "01a01234-1234-7234-8234-123412341235"
            )

          send(test_pid, {:result, result})
        end)

        assert_receive {:result, result}, 1000
        assert {:error, %DBConnection.OwnershipError{}} = result
      end)

    assert log =~ "Activity logging"
  end
end
