defmodule PhoenixKitBilling.NotificationContractsTest do
  @moduledoc """
  Contracts between the registered notification types and the code that is
  supposed to emit them.

  These need no database on purpose. Both defects they pin were invisible to
  a DB-backed test: nothing raised, nothing failed a changeset — a registered
  action simply had no producer, and a link pointed at a route no install
  has. Only reading the module against itself catches that.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Notifications
  alias PhoenixKitBilling.Paths

  @notifications_source "lib/phoenix_kit_billing/notifications.ex"

  test "every registered notification action has a producer" do
    # A registered action nothing ever emits is a dead toggle in every user's
    # notification preferences. `billing.payment_failed` was exactly that:
    # declared, documented as the one operators need, and never called —
    # both provider failure paths (the webhook processor and the renewal
    # worker) went straight to a Logger line.
    [%{sub_types: subs}] = PhoenixKitBilling.notification_types()

    producers = File.read!(@notifications_source)

    call_sites =
      "lib/phoenix_kit_billing/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&(&1 =~ "notifications.ex"))
      |> Enum.map_join("\n", &File.read!/1)

    for action <- Enum.flat_map(subs, & &1.actions) do
      [_module, function] = String.split(action, ".", parts: 2)

      assert producers =~ ~s|"#{action}"|,
             "#{action} is registered but #{@notifications_source} never names it"

      # The customer-facing sends are fanned out from inside the admin ones,
      # so only the admin actions need a call site of their own.
      unless String.starts_with?(function, "your_") do
        assert call_sites =~ "Notifications.#{function}(",
               "#{action} is registered but nothing in the module ever calls " <>
                 "Notifications.#{function}/1"
      end
    end
  end

  test "notification links point at routes this module registers" do
    # A notification link is followed from an inbox, an email or Telegram,
    # long after the send. `/dashboard/invoices/<uuid>` was linked for every
    # customer notification and no install has that route — each one landed
    # on a 404.
    # `Routes.path/1` may prefix a locale ("/en/dashboard/..."), so match on
    # the tail rather than the whole path.
    registered = Enum.map(PhoenixKitBilling.user_dashboard_tabs(), &"/dashboard/#{&1.path}")

    for path <- [Paths.user_orders(), Paths.user_billing_profiles()] do
      assert Enum.any?(registered, &String.ends_with?(path, &1)),
             "#{path} is not under any tab from user_dashboard_tabs/0 (#{inspect(registered)})"
    end

    # And the notification module must go through Paths rather than
    # hand-rolling a customer URL, which is how the dead link got in.
    refute File.read!(@notifications_source) =~ ~s|path("/dashboard|
  end

  test "a decline reason is truncated on a CHARACTER boundary" do
    # Providers return localized decline reasons. Cutting at 100 BYTES can
    # land mid-codepoint, and the invalid string is then rejected by both the
    # JSON encoder and Postgres — so the notification reporting a failed
    # payment fails itself.
    assert :ok =
             Notifications.payment_failed(
               %{invoice_number: "INV-1"},
               String.duplicate("é", 200)
             )
  end
end
