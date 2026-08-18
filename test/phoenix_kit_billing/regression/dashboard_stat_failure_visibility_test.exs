defmodule PhoenixKitBilling.Regression.DashboardStatFailureVisibilityTest do
  @moduledoc """
  `get_dashboard_stats/0`'s eight private helpers (`count_orders`,
  `count_invoices`, `count_currencies`, `count_orders_since`,
  `count_invoices_since`, `count_invoices_by_status`,
  `calculate_paid_revenue`, `calculate_pending_revenue`) all rescued a
  query failure straight to `0` / `Decimal.new(0)` with no log line — a
  real query failure (bad connection, a migration mid-flight, a locked
  table) rendered on the admin dashboard as "$0 pending revenue" / "0
  orders", indistinguishable from an actually-empty, healthy system.

  Unlike `activity.ex`'s rescue (see
  `activity_log_failure_visibility_test.exs`), these functions call
  `repo()` directly with no wrapping layer underneath that already
  rescues — so this genuinely is reachable, not dead code. Reproduced
  for real: `async: true` + an unowned `spawn/1` process triggers a
  real `DBConnection.OwnershipError` on each query, same technique as
  the Activity test.

  The fallback values (`0`, `Decimal.new(0)`) are still the right thing
  to show — a stat tile crashing the whole admin dashboard over one
  transient query error would be worse than a wrong-looking number — so
  this only tests that the failure is now LOGGED, not that the return
  shape changed.
  """

  use PhoenixKitBilling.DataCase, async: true

  import ExUnit.CaptureLog

  alias PhoenixKitBilling, as: Billing

  test "a query failure during get_dashboard_stats/0 is logged, not silent" do
    test_pid = self()

    log =
      capture_log(fn ->
        spawn(fn ->
          stats = Billing.get_dashboard_stats()
          send(test_pid, {:stats, stats})
        end)

        assert_receive {:stats, stats}, 1000

        assert stats.total_orders == 0
        assert stats.total_invoices == 0
        assert Decimal.equal?(stats.total_paid_revenue, Decimal.new(0))
        assert Decimal.equal?(stats.pending_revenue, Decimal.new(0))
      end)

    assert log =~ "dashboard stat count_orders failed"
    assert log =~ "dashboard stat count_invoices failed"
    assert log =~ "dashboard stat calculate_paid_revenue failed"
    assert log =~ "dashboard stat calculate_pending_revenue failed"
  end
end
