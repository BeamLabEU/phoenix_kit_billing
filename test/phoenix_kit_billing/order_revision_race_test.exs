defmodule PhoenixKitBilling.OrderRevisionRaceTest do
  @moduledoc """
  The revision under real concurrency. The sandbox shares one connection, so
  tasks inside it only take turns; these tests leave it (`:auto` mode) and use
  separate connections that really race for the row lock, then delete what they
  committed. `async: false`: it changes the sandbox mode for the whole run.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Order
  alias PhoenixKitBilling.Test.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    PhoenixKit.Settings.update_setting("billing_enabled", "true")

    {:ok, user} =
      Auth.register_user(%{
        "email" => "race-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("10.00"),
        "currency" => "EUR",
        "status" => "pending",
        "billing_snapshot" => %{"email" => "g@example.com"}
      })

    on_exit(fn ->
      Repo.delete_all(from(o in Order, where: o.uuid == ^order.uuid))
      Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{order: order}
  end

  defp parallel(count, fun) do
    1..count
    |> Enum.map(fn n -> Task.async(fn -> fun.(n) end) end)
    |> Enum.map(&Task.await(&1, 30_000))
  end

  test "parallel updates from the same stale struct all count", %{order: order} do
    results = parallel(8, fn n -> Billing.update_order(order, %{"notes" => "note #{n}"}) end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Order.revision(Billing.get_order(order.uuid)) == 9
  end

  test "an update racing a mark for the revision it read never leaves a stale mark", %{
    order: order
  } do
    for round <- 1..20 do
      current = Billing.get_order(order.uuid)
      revision = Order.revision(current)

      [update, mark] =
        parallel(2, fn
          1 -> Billing.update_order(current, %{"notes" => "round #{round}"})
          2 -> Billing.put_order_sync(current, %{state: "synced", revision: revision})
        end)

      assert {:ok, _} = update
      stored = Billing.get_order(order.uuid)

      case mark do
        {:ok, _} ->
          # The mark won the lock; the update then moved the revision on.
          assert Order.revision(stored) == revision + 1
          assert Order.sync(stored)["state"] == "pending"

        {:error, :stale_revision} ->
          # The update won; the mark wrote nothing for the old revision.
          assert stored.metadata["sync"]["revision"] != revision or
                   is_nil(stored.metadata["sync"])
      end
    end
  end
end
