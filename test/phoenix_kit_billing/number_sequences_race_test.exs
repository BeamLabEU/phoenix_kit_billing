defmodule PhoenixKitBilling.NumberSequencesRaceTest do
  @moduledoc """
  Numbers under real concurrency. The sandbox shares one connection, so tasks
  inside it only take turns; these tests leave it (`:auto` mode) and use
  separate connections that really race for the counter row, then delete what
  they committed. `async: false`: it changes the sandbox mode for the whole run.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Order
  alias PhoenixKitBilling.Test.Repo
  alias PhoenixKitBilling.Transaction

  @sequences "phoenix_kit_billing_number_sequences"

  setup do
    Sandbox.mode(Repo, :auto)
    PhoenixKit.Settings.update_setting("billing_enabled", "true")
    Repo.delete_all(from(s in @sequences))

    {:ok, user} =
      Auth.register_user(%{
        "email" => "numbers-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    on_exit(fn ->
      Repo.delete_all(from(t in Transaction, where: t.user_uuid == ^user.uuid))
      Repo.delete_all(from(i in Invoice, where: i.user_uuid == ^user.uuid))
      Repo.delete_all(from(o in Order, where: o.user_uuid == ^user.uuid))
      Repo.delete_all(from(s in @sequences))
      Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{user: user}
  end

  defp parallel(count, fun) do
    1..count
    |> Enum.map(fn n -> Task.async(fn -> fun.(n) end) end)
    |> Enum.map(&Task.await(&1, 30_000))
  end

  defp order_attrs do
    %{
      "total" => Decimal.new("10.00"),
      "currency" => "EUR",
      "status" => "pending",
      "billing_snapshot" => %{"email" => "buyer@example.com"}
    }
  end

  # The suffix numbers, sorted.
  defp sequence(records, field) do
    records
    |> Enum.map(fn {:ok, record} ->
      record |> Map.fetch!(field) |> String.split("-") |> List.last()
    end)
    |> Enum.sort()
  end

  defp expected(range), do: Enum.map(range, &String.pad_leading(to_string(&1), 4, "0"))

  test "concurrent orders, the first of the year among them, get distinct consecutive numbers", %{
    user: user
  } do
    # No counter row yet: every task races to create it.
    first = parallel(8, fn _ -> Billing.create_order(user, order_attrs()) end)
    assert Enum.all?(first, &match?({:ok, _}, &1))
    assert sequence(first, :order_number) == expected(1..8)

    # Counter row exists: every task races for its lock.
    second = parallel(8, fn _ -> Billing.create_order(user, order_attrs()) end)
    assert Enum.all?(second, &match?({:ok, _}, &1))
    assert sequence(first ++ second, :order_number) == expected(1..16)
  end

  test "concurrent orders after a delete never meet a taken number", %{user: user} do
    {:ok, first} = Billing.create_order(user, order_attrs())
    {:ok, _} = Billing.create_order(user, order_attrs())
    Repo.delete!(first)

    results = parallel(6, fn _ -> Billing.create_order(user, order_attrs()) end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert sequence(results, :order_number) == expected(3..8)
  end

  test "concurrent standalone invoices get distinct consecutive numbers", %{user: user} do
    attrs = %{
      total: Decimal.new("10.00"),
      currency: "EUR",
      billing_details: %{"email" => "b@example.com"}
    }

    results = parallel(8, fn _ -> Billing.create_invoice(user, attrs) end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert sequence(results, :invoice_number) == expected(1..8)
  end

  test "concurrent receipts get distinct consecutive numbers", %{user: user} do
    {:ok, order} = Billing.create_order(user, order_attrs())

    invoices =
      for _ <- 1..6 do
        {:ok, invoice} = Billing.create_invoice_from_order(order)

        {:ok, partly} =
          invoice |> Ecto.Changeset.change(%{paid_amount: Decimal.new("4.00")}) |> Repo.update()

        partly
      end

    results = parallel(6, fn n -> Billing.generate_receipt(Enum.at(invoices, n - 1)) end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert sequence(results, :receipt_number) == expected(1..6)
  end
end
