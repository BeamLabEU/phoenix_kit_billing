defmodule PhoenixKitBilling.SubscriptionChargeRaceTest do
  @moduledoc """
  A charge in flight against whatever else wants the subscription or its invoice, under
  real concurrency (separate connections, outside the sandbox; `async: false` because
  it changes the sandbox mode for the run).

  The invoice is committed before the charge, so it is out in the open while the
  provider answers. These run the others from inside the stubbed provider call, which
  is when the first worker holds its locks.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitBilling, as: Billing

  alias PhoenixKitBilling.{
    Invoice,
    PaymentMethod,
    Subscription,
    SubscriptionType,
    Transaction
  }

  alias PhoenixKitBilling.Test.Repo
  alias PhoenixKitBilling.Workers.SubscriptionRenewalWorker

  setup do
    Sandbox.mode(Repo, :auto)
    Settings.update_setting("billing_enabled", "true")
    Settings.update_setting("billing_stripe_enabled", "true")
    Settings.update_setting("billing_stripe_secret_key", "sk_test_123")
    Application.put_env(:phoenix_kit_billing, :stripe_req_options, plug: {Req.Test, __MODULE__})

    {:ok, user} =
      Auth.register_user(%{
        "email" => "charge-race-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    {:ok, type} =
      Billing.create_subscription_type(%{
        name: "Plan",
        slug: "plan-#{System.unique_integer([:positive])}",
        price: Decimal.new("5.00"),
        currency: "EUR"
      })

    {:ok, method} =
      %PaymentMethod{}
      |> PaymentMethod.changeset(%{
        provider: "stripe",
        provider_payment_method_id: "pm_#{System.unique_integer([:positive])}",
        provider_customer_id: "cus_1",
        user_uuid: user.uuid,
        status: "active"
      })
      |> Repo.insert()

    {:ok, subscription} =
      Billing.create_subscription(user.uuid, %{
        subscription_type_uuid: type.uuid,
        payment_method_uuid: method.uuid,
        trial_days: 30
      })

    ends = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    subscription =
      subscription
      |> Ecto.Changeset.change(status: "active", trial_end: nil, current_period_end: ends)
      |> Repo.update!()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_billing, :stripe_req_options)
      Settings.update_setting("billing_stripe_enabled", "false")
      Settings.update_setting("billing_stripe_secret_key", "")

      invoices = from(i in Invoice, where: i.user_uuid == ^user.uuid, select: i.uuid)
      Repo.delete_all(from(t in Transaction, where: t.invoice_uuid in subquery(invoices)))
      Repo.delete_all(from(i in Invoice, where: i.user_uuid == ^user.uuid))
      Repo.delete_all(from(s in Subscription, where: s.user_uuid == ^user.uuid))
      Repo.delete_all(from(p in PaymentMethod, where: p.user_uuid == ^user.uuid))
      Repo.delete_all(from(t in SubscriptionType, where: t.uuid == ^type.uuid))
      Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{subscription: subscription, user: user, type: type, method: method}
  end

  defp renew(subscription) do
    SubscriptionRenewalWorker.perform(%Oban.Job{
      args: %{"subscription_uuid" => subscription.uuid}
    })
  end

  # Answers the provider call after `during` has run. It counts the charges too.
  defp stub_charge(charges, during) do
    Req.Test.stub(__MODULE__, fn conn ->
      :counters.add(charges, 1, 1)
      during.()
      id = System.unique_integer([:positive])

      Req.Test.json(conn, %{
        "id" => "pi_#{id}",
        "status" => "succeeded",
        "latest_charge" => "ch_#{id}"
      })
    end)
  end

  test "a second worker waits, finds the period moved on and charges nothing", %{
    subscription: subscription
  } do
    charges = :counters.new(1, [])
    test_pid = self()

    stub_charge(charges, fn ->
      second = Task.async(fn -> renew(subscription) end)
      send(test_pid, {:second, second, Task.yield(second, 300)})
    end)

    assert {:ok, %Subscription{}} = renew(subscription)

    assert_received {:second, second, nil}
    assert {:ok, :skipped} = Task.await(second, 5_000)
    assert :counters.get(charges, 1) == 1
  end

  test "the daily run that meets a first charge in flight waits, and charges nothing", %{
    user: user,
    type: type,
    method: method
  } do
    charges = :counters.new(1, [])
    test_pid = self()

    stub_charge(charges, fn ->
      started =
        Repo.one!(
          from(s in Subscription,
            where: s.user_uuid == ^user.uuid and s.current_period_end <= ^DateTime.utc_now()
          )
        )

      worker = Task.async(fn -> renew(started) end)
      send(test_pid, {:worker, worker, Task.yield(worker, 300)})
    end)

    assert {:ok, %Subscription{status: "active"}} =
             Billing.create_subscription(user.uuid, %{
               subscription_type_uuid: type.uuid,
               payment_method_uuid: method.uuid
             })

    assert_received {:worker, worker, nil}
    assert {:ok, :skipped} = Task.await(worker, 5_000)
    assert :counters.get(charges, 1) == 1
  end

  test "a void waits for the charge in flight, and finds the invoice paid", %{
    subscription: subscription
  } do
    charges = :counters.new(1, [])
    test_pid = self()

    stub_charge(charges, fn ->
      invoice = Repo.one!(from(i in Invoice, where: i.subscription_uuid == ^subscription.uuid))
      void = Task.async(fn -> Billing.void_invoice(invoice) end)
      send(test_pid, {:void, void, Task.yield(void, 300)})
    end)

    assert {:ok, %Subscription{}} = renew(subscription)

    assert_received {:void, void, nil}
    assert {:error, :invoice_not_voidable} = Task.await(void, 5_000)

    assert Repo.one!(from(i in Invoice, where: i.subscription_uuid == ^subscription.uuid)).status ==
             "paid"
  end

  test "an admin's pause waits for the charge, and applies to the renewed subscription", %{
    subscription: subscription
  } do
    charges = :counters.new(1, [])
    test_pid = self()

    stub_charge(charges, fn ->
      pause = Task.async(fn -> Billing.pause_subscription(subscription) end)
      send(test_pid, {:pause, pause, Task.yield(pause, 300)})
    end)

    assert {:ok, %Subscription{}} = renew(subscription)

    assert_received {:pause, pause, nil}
    assert {:ok, %Subscription{status: "paused"}} = Task.await(pause, 5_000)

    stored = Repo.get!(Subscription, subscription.uuid)
    assert stored.status == "paused"
    assert DateTime.compare(stored.current_period_end, subscription.current_period_end) == :gt
  end
end
