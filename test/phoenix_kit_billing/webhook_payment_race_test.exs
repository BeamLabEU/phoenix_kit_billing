defmodule PhoenixKitBilling.WebhookPaymentRaceTest do
  @moduledoc """
  A provider's payment event against the worker recording the same charge, under real
  concurrency (separate connections, outside the sandbox; `async: false` because it
  changes the sandbox mode for the run).

  The subscription workers commit an invoice before charging it and hold it locked
  across the charge, so the event can read it as unpaid, wait for the lock and find no
  balance left. That is the payment arriving twice, not a payment gone wrong: raised
  as `:exceeds_remaining` it would tell the admins a paid invoice had failed.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Invoice, Transaction, WebhookEvent, WebhookProcessor}
  alias PhoenixKitBilling.Test.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    PhoenixKit.Settings.update_setting("billing_enabled", "true")

    {:ok, user} =
      Auth.register_user(%{
        "email" => "webhook-race-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    {:ok, invoice} =
      Billing.create_invoice(user, %{
        total: Decimal.new("10.00"),
        currency: "EUR",
        status: "sent",
        billing_details: %{"email" => "buyer@example.com"}
      })

    event_id = "evt_race_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Repo.delete_all(from(t in Transaction, where: t.invoice_uuid == ^invoice.uuid))
      Repo.delete_all(from(i in Invoice, where: i.uuid == ^invoice.uuid))
      Repo.delete_all(from(e in WebhookEvent, where: e.event_id == ^event_id))
      Repo.delete_all(from(u in User, where: u.uuid == ^user.uuid))
      Sandbox.mode(Repo, :manual)
    end)

    %{invoice: invoice, event_id: event_id}
  end

  defp payment_event(invoice, event_id, cents) do
    %{
      event_id: event_id,
      type: "payment.succeeded",
      provider: :stripe,
      data: %{
        invoice_uuid: invoice.uuid,
        amount: cents,
        currency: "EUR",
        charge_id: "ch_#{event_id}"
      }
    }
  end

  test "an event that waited out the recording of its charge is answered as paid", %{
    invoice: invoice,
    event_id: event_id
  } do
    test_pid = self()

    worker =
      Task.async(fn ->
        Repo.transaction(fn ->
          {:ok, _} = Billing.mark_invoice_paid(invoice)
          send(test_pid, :recorded)

          receive do
            :commit -> :ok
          end
        end)
      end)

    assert_receive :recorded, 5_000

    webhook =
      Task.async(fn -> WebhookProcessor.process(payment_event(invoice, event_id, 1000)) end)

    assert Task.yield(webhook, 300) == nil

    send(worker.pid, :commit)
    assert {:ok, {:ok, :ok}} = Task.yield(worker, 5_000)
    assert {:ok, {:ok, :already_paid}} = Task.yield(webhook, 5_000)

    assert [_one_row] =
             Repo.all(from(t in Transaction, where: t.invoice_uuid == ^invoice.uuid))
  end

  test "more than an unpaid invoice is owed still fails the event", %{
    invoice: invoice,
    event_id: event_id
  } do
    assert {:error, :exceeds_remaining} =
             WebhookProcessor.process(payment_event(invoice, event_id, 2000))
  end
end
