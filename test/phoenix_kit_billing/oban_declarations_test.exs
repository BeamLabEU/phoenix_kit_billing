defmodule PhoenixKitBilling.ObanDeclarationsTest do
  @moduledoc """
  Billing declares its Oban queue and its cron through core's
  `PhoenixKit.Module` callbacks (`oban_queues/0`, `oban_crons/0`), so
  `mix phoenix_kit.install` / `update` write them into a host's Oban config
  instead of the host copying them from the docs.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Workers.SubscriptionRenewalWorker

  test "the renewal run is the one cron entry, on a declared queue" do
    assert [{"0 6 * * *", SubscriptionRenewalWorker}] = Billing.oban_crons()

    for {_cron, worker} <- Billing.oban_crons() do
      assert Code.ensure_loaded?(worker)
      queue = worker.new(%{}).changes.queue |> String.to_existing_atom()
      assert Keyword.has_key?(Billing.oban_queues(), queue)
    end
  end

  test "core's readers take both declarations, without conflicts" do
    assert {crons, []} = PhoenixKit.ObanCrons.declared([Billing])
    assert {"0 6 * * *", SubscriptionRenewalWorker} in crons

    assert %{name: :billing, limit: 10} =
             Enum.find(PhoenixKit.ObanQueues.declared([Billing]), &(&1.name == :billing))
  end

  test "the legacy namespace declares the same" do
    assert PhoenixKit.Modules.Billing.oban_crons() == Billing.oban_crons()
  end

  test "the batch run does nothing while billing is disabled" do
    Settings.update_setting("billing_enabled", "false")
    on_exit(fn -> Settings.update_setting("billing_enabled", "true") end)

    assert :ok = SubscriptionRenewalWorker.perform(%Oban.Job{args: %{}})
  end
end
