defmodule PhoenixKitBilling.OrderAmountRaceTest do
  @moduledoc """
  A new order total against an invoice being created for the old one, under real
  concurrency (separate connections, outside the sandbox; `async: false` because it
  changes the sandbox mode for the run).

  `update_order/2` looks for an invoice before it writes. An invoice still in its
  transaction is not there to be seen, so the edit has to wait for it: the row is
  taken `FOR UPDATE`, which conflicts with the `FOR KEY SHARE` the invoice insert
  holds on the order.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Order}
  alias PhoenixKitBilling.Test.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    PhoenixKit.Settings.update_setting("billing_enabled", "true")

    {:ok, user} =
      Auth.register_user(%{
        "email" => "order-amount-race-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    {:ok, order} =
      Billing.create_order(user, %{
        "total" => Decimal.new("25.00"),
        "currency" => "EUR",
        "status" => "pending",
        "billing_snapshot" => %{"email" => "buyer@example.com"}
      })

    on_exit(fn ->
      Repo.delete_all(from(i in Invoice, where: i.order_uuid == ^order.uuid))
      Repo.delete_all(from(o in Order, where: o.uuid == ^order.uuid))
      Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{order: order}
  end

  test "an edit of the total waits for the invoice in flight, and is refused", %{order: order} do
    test_pid = self()

    creator =
      Task.async(fn ->
        Repo.transaction(fn ->
          result = Billing.create_invoice_from_order(order)
          send(test_pid, :created)

          receive do
            :commit -> result
          end
        end)
      end)

    assert_receive :created, 5_000

    editor = Task.async(fn -> Billing.update_order(order, %{"total" => "100.00"}) end)
    assert Task.yield(editor, 300) == nil

    send(creator.pid, :commit)
    assert {:ok, {:ok, {:ok, %Invoice{}}}} = Task.yield(creator, 5_000)
    assert {:ok, {:error, :order_amount_invoiced}} = Task.yield(editor, 5_000)

    assert Decimal.equal?(Repo.get!(Order, order.uuid).total, "25.00")
  end
end
