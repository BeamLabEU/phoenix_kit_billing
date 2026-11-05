defmodule PhoenixKitBilling.OrderPaymentRaceTest do
  @moduledoc """
  Recording a checkout session's context against a concurrent void, under real
  concurrency (separate connections, outside the sandbox; `async: false`
  because it changes the sandbox mode for the run).

  The context is written back with the whole `metadata`, which also holds the
  void trail: the charges that landed on a void invoice and still have to be
  refunded. Read without the row lock, the write lost a trail committed
  between the read and the write.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, OrderPayment}
  alias PhoenixKitBilling.Test.Repo

  @url "https://checkout.stripe.test/1"
  @opts [success_url: "https://shop.test/done", cancel_url: "https://shop.test/cancel"]

  setup do
    Sandbox.mode(Repo, :auto)
    PhoenixKit.Settings.update_setting("billing_enabled", "true")

    {:ok, user} =
      Auth.register_user(%{
        "email" => "checkout-race-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    {:ok, invoice} =
      Billing.create_invoice(user, %{
        total: Decimal.new("10.00"),
        currency: "EUR",
        status: "sent",
        billing_details: %{"email" => "buyer@example.com"}
      })

    :ok =
      Billing.record_checkout_session(invoice, "stripe", %{id: "cs_test_1", url: @url})

    on_exit(fn ->
      Repo.delete_all(from(i in Invoice, where: i.user_uuid == ^user.uuid))
      Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{invoice: Billing.get_invoice!(invoice.uuid)}
  end

  # Runs `fun` in a transaction that stays open, holding what `fun` locked,
  # until told to commit.
  defp hold_open(fun) do
    test_pid = self()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          result = fun.()
          send(test_pid, {:holding, result})

          receive do
            :commit -> result
          end
        end)
      end)

    assert_receive {:holding, result}, 5_000
    {task, result}
  end

  test "a void in flight keeps its trail: the context waits for it, then merges into it", %{
    invoice: invoice
  } do
    {voider, {:ok, _}} = hold_open(fn -> Billing.void_invoice(invoice, "Duplicate") end)

    recorder = Task.async(fn -> OrderPayment.record_checkout_context(invoice, @url, @opts) end)
    assert Task.yield(recorder, 300) == nil

    send(voider.pid, :commit)
    assert {:ok, {:ok, {:ok, _}}} = Task.yield(voider, 5_000)
    assert {:ok, :ok} = Task.yield(recorder, 5_000)

    stored = Billing.get_invoice!(invoice.uuid)
    assert stored.status == "void"
    assert stored.metadata["void"]["reason"] == "Duplicate"
    assert stored.metadata["checkout"]["success_url"] == @opts[:success_url]
  end

  test "a session replaced since is left alone", %{invoice: invoice} do
    assert :ok = OrderPayment.record_checkout_context(invoice, "https://other.test/2", @opts)

    stored = Billing.get_invoice!(invoice.uuid)
    assert stored.metadata["checkout"]["url"] == @url
    refute Map.has_key?(stored.metadata["checkout"], "success_url")
  end
end
