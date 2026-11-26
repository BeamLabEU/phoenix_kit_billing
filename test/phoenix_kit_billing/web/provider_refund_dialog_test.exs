defmodule PhoenixKitBilling.Web.ProviderRefundDialogTest do
  @moduledoc """
  The admin refund dialog with a provider chosen: the refund is made at the
  provider (`refund_at_provider/3`), over a stubbed Stripe, under one
  idempotency key per opening of the dialog.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Currency, Invoice, Transaction}
  alias PhoenixKitBilling.Test.Repo

  import Ecto.Query

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    Settings.update_setting("billing_stripe_enabled", "true")
    Settings.update_setting("billing_stripe_secret_key", "sk_test_123")
    Application.put_env(:phoenix_kit_billing, :stripe_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_billing, :stripe_req_options)
      Settings.update_setting("billing_stripe_enabled", "false")
      Settings.update_setting("billing_stripe_secret_key", "")
    end)

    Repo.delete_all(Currency)

    {:ok, _eur} =
      Billing.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        is_default: true,
        exchange_rate: "1.0"
      })

    test_pid = self()

    # Stripe answers a repeated key with the refund it already made.
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      key = conn |> Plug.Conn.get_req_header("idempotency-key") |> List.first()
      send(test_pid, {:stripe_refund, params, key})

      Req.Test.json(conn, %{
        "id" => "re_" <> Integer.to_string(:erlang.phash2(key)),
        "object" => "refund",
        "amount" => String.to_integer(params["amount"]),
        "currency" => "eur",
        "status" => "succeeded",
        "charge" => "ch_1",
        "payment_intent" => "pi_123"
      })
    end)

    admin = fixture_user()
    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: admin.uuid, email: admin.email))}
  end

  defp paid_invoice do
    {:ok, invoice} =
      Billing.create_invoice(fixture_user(), %{total: Decimal.new("30.00"), currency: "EUR"})

    {:ok, invoice, _} = Billing.send_invoice(invoice, send_email: false)

    {:ok, _} =
      Billing.record_payment(
        invoice,
        %{
          amount: "30.00",
          payment_method: "stripe",
          provider_transaction_id: "pi_123",
          provider_data: %{"payment_intent_id" => "pi_123"}
        },
        nil
      )

    Repo.get!(Invoice, invoice.uuid)
  end

  defp refund_rows(invoice) do
    Repo.all(from(t in Transaction, where: t.invoice_uuid == ^invoice.uuid and t.amount < 0))
  end

  test "a refund submitted twice from one dialog is made at Stripe once", %{conn: conn} do
    invoice = paid_invoice()
    {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

    view |> element("button[phx-click=open_refund_modal]") |> render_click()

    params = %{"amount" => "10.00", "payment_method" => "stripe", "description" => "late cancel"}
    render_change(view, "update_refund_form", params)
    assert render(view) =~ "refund-at-provider-note"

    render_hook(view, "record_refund", %{})
    # The same submit reaching the server again (a double click).
    render_hook(view, "record_refund", %{})

    assert_received {:stripe_refund, %{"amount" => "1000"}, key}
    assert_received {:stripe_refund, %{"amount" => "1000"}, ^key}
    assert key =~ "pkb-admin-refund:"

    assert [row] = refund_rows(invoice)
    assert Decimal.equal?(row.amount, Decimal.new("-10.00"))
    assert Decimal.equal?(Repo.get!(Invoice, invoice.uuid).paid_amount, Decimal.new("20.00"))

    # A new opening of the dialog is a new refund.
    view |> element("button[phx-click=open_refund_modal]") |> render_click()
    render_change(view, "update_refund_form", params)
    render_hook(view, "record_refund", %{})

    assert_received {:stripe_refund, %{"amount" => "1000"}, other_key}
    assert other_key != key
    assert length(refund_rows(invoice)) == 2
  end

  test "after a lost answer the same amount is retried under the same key, a new amount is not",
       %{conn: conn} do
    invoice = paid_invoice()
    test_pid = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    # The first answer is lost (Stripe made the refund, billing saw an error).
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      key = conn |> Plug.Conn.get_req_header("idempotency-key") |> List.first()
      send(test_pid, {:stripe_refund, params, key})

      if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"code" => "lost", "message" => "lost"}})
      else
        Req.Test.json(conn, %{
          "id" => "re_" <> Integer.to_string(:erlang.phash2(key)),
          "object" => "refund",
          "amount" => String.to_integer(params["amount"]),
          "currency" => "eur",
          "status" => "succeeded",
          "charge" => "ch_1",
          "payment_intent" => "pi_123"
        })
      end
    end)

    {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
    view |> element("button[phx-click=open_refund_modal]") |> render_click()

    params = %{"amount" => "10.00", "payment_method" => "stripe", "description" => "late cancel"}
    render_change(view, "update_refund_form", params)
    render_hook(view, "record_refund", %{})
    render_change(view, "update_refund_form", %{params | "amount" => "10"})
    render_hook(view, "record_refund", %{})

    assert_received {:stripe_refund, _, key}
    assert_received {:stripe_refund, _, ^key}

    render_change(view, "update_refund_form", %{params | "amount" => "5.00"})
    render_hook(view, "record_refund", %{})
    assert_received {:stripe_refund, %{"amount" => "500"}, other}
    assert other != key
  end
end
