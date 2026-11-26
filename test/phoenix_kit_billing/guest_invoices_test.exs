defmodule PhoenixKitBilling.GuestInvoicesTest do
  @moduledoc """
  Invoices for a payer without an account: `create_guest_invoice/2`, the signed
  payment link (`InvoiceLinks`), the public payment page
  (`Web.GuestInvoice`) and what admins see.
  """

  use PhoenixKitBilling.LiveCase, async: false
  use Oban.Testing, repo: PhoenixKitBilling.Test.Repo

  alias PhoenixKit.PubSub.Manager
  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Events, Invoice, InvoiceLinks, Providers, WebhookProcessor}
  alias PhoenixKitBilling.Test.Repo
  alias PhoenixKitBilling.Workers.InvoiceEventWorker

  @guest %{email: "ann@example.com", name: "Ann Guest", phone: "+372 5555 5555"}

  defmodule PaidHandler do
    @behaviour PhoenixKitBilling.InvoiceEventHandler

    @impl true
    def handle_invoice_event(:paid, invoice) do
      send(:guest_invoices_test, {:paid, invoice.uuid, invoice.metadata["booking_uuid"]})
      :ok
    end

    def handle_invoice_event(_event, _invoice), do: :ok
  end

  setup do
    Application.put_env(:phoenix_kit_billing, :invoice_link_secret, String.duplicate("k", 64))
    on_exit(fn -> Application.delete_env(:phoenix_kit_billing, :invoice_link_secret) end)
    :ok
  end

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{
        total: Decimal.new("15.00"),
        subtotal: Decimal.new("15.00"),
        currency: "EUR",
        line_items: [
          %{"name" => "Yoga class", "quantity" => 1, "unit_price" => "15.00", "total" => "15.00"}
        ]
      },
      extra
    )
  end

  defp guest_invoice!(extra \\ %{}) do
    {:ok, invoice} = Billing.create_guest_invoice(@guest, attrs(extra))
    {:ok, invoice, _} = Billing.send_invoice(invoice, send_email: false)
    invoice
  end

  describe "create_guest_invoice/2" do
    test "makes an invoice with no user, addressed to the guest's email" do
      assert {:ok, invoice} = Billing.create_guest_invoice(@guest, attrs())

      assert invoice.user_uuid == nil
      assert invoice.status == "draft"
      assert invoice.billing_details["email"] == "ann@example.com"
      assert invoice.billing_details["name"] == "Ann Guest"
      assert invoice.billing_details["phone"] == "+372 5555 5555"
      assert invoice.billing_details["type"] == "individual"
      assert Invoice.payer_name(invoice.billing_details) == "Ann Guest"
    end

    test "takes string keys and keeps billing details the caller gave" do
      assert {:ok, invoice} =
               Billing.create_guest_invoice(
                 %{"email" => " bob@example.com ", "first_name" => "Bob"},
                 %{
                   "total" => "5.00",
                   "currency" => "EUR",
                   "billing_details" => %{"city" => "Tallinn"},
                   "user_uuid" => Ecto.UUID.generate()
                 }
               )

      assert invoice.user_uuid == nil
      assert invoice.billing_details["email"] == "bob@example.com"
      assert invoice.billing_details["city"] == "Tallinn"
    end

    test "is announced on its own topic, and on no user topic" do
      Manager.subscribe("phoenix_kit:billing:invoices:user:")
      Events.subscribe_invoices()

      {:ok, invoice} = Billing.create_guest_invoice(@guest, attrs())
      assert_received {:invoice_created, %Invoice{uuid: uuid}}
      assert uuid == invoice.uuid
      refute_received {:invoice_created, _}

      Events.subscribe_invoice(invoice.uuid)
      {:ok, _sent, _} = Billing.send_invoice(invoice, send_email: false)
      # Once on the global topic, once on the invoice's own.
      assert_received {:invoice_sent, _}
      assert_received {:invoice_sent, _}
      refute_received {:invoice_sent, _}
    end

    test "refuses a missing or malformed email" do
      assert {:error, :invalid_email} = Billing.create_guest_invoice(%{name: "X"}, attrs())
      assert {:error, :invalid_email} = Billing.create_guest_invoice(%{email: "nope"}, attrs())
    end

    test "admins find it by the guest's email" do
      invoice = guest_invoice!()

      {found, total} = Billing.list_invoices_with_count(search: "ann@example")
      assert total >= 1
      assert invoice.uuid in Enum.map(found, & &1.uuid)
    end
  end

  describe "InvoiceLinks" do
    test "a token finds its invoice; anything else finds nothing" do
      invoice = guest_invoice!()
      token = InvoiceLinks.token(invoice)

      assert %Invoice{uuid: uuid} = Billing.get_invoice_by_pay_token(token)
      assert uuid == invoice.uuid

      assert Billing.get_invoice_by_pay_token(token <> "x") == nil
      assert Billing.get_invoice_by_pay_token("garbage") == nil
      assert Billing.get_invoice_by_pay_token(nil) == nil
    end

    test "a token signed with another secret is refused" do
      invoice = guest_invoice!()
      token = InvoiceLinks.token(invoice)

      Application.put_env(:phoenix_kit_billing, :invoice_link_secret, String.duplicate("z", 64))
      assert Billing.get_invoice_by_pay_token(token) == nil
    end

    test "a link past its max age is refused" do
      invoice = guest_invoice!()
      token = InvoiceLinks.token(invoice)

      Application.put_env(:phoenix_kit_billing, :invoice_link_max_age, -1)
      on_exit(fn -> Application.delete_env(:phoenix_kit_billing, :invoice_link_max_age) end)

      assert Billing.get_invoice_by_pay_token(token) == nil
    end

    test "an invoice edit cannot reset the link generation and bring revoked links back" do
      # Only a draft is editable; its link is minted before it is sent.
      {:ok, draft} = Billing.create_guest_invoice(@guest, attrs())
      old_token = InvoiceLinks.token(draft)
      {:ok, _} = Billing.revoke_invoice_pay_links(draft)

      # A stale struct's metadata, or a forged generation, written back.
      {:ok, _} = Billing.update_invoice(draft, %{metadata: %{"note" => "x"}})
      {:ok, _} = Billing.update_invoice(draft, %{metadata: %{"pay_link_generation" => 0}})

      {:ok, invoice, _} = Billing.send_invoice(Repo.get!(Invoice, draft.uuid), send_email: false)
      assert Billing.get_invoice_by_pay_token(old_token) == nil
      assert Repo.get!(Invoice, invoice.uuid).metadata["pay_link_generation"] == 1
    end

    test "a draft is not shown through its link until it is sent" do
      {:ok, draft} = Billing.create_guest_invoice(@guest, attrs())
      token = InvoiceLinks.token(draft)

      assert Billing.get_invoice_by_pay_token(token) == nil

      {:ok, _sent, _} = Billing.send_invoice(draft, send_email: false)
      assert %Invoice{status: "sent"} = Billing.get_invoice_by_pay_token(token)
    end

    test "an invoice in the trash is not found through its link" do
      {:ok, draft} = Billing.create_guest_invoice(@guest, attrs())
      token = InvoiceLinks.token(draft)
      {:ok, _} = Billing.trash_invoice(draft)

      assert Billing.get_invoice_by_pay_token(token) == nil
    end

    test "revoking one invoice's links stops them, and only them" do
      invoice = guest_invoice!()
      other = guest_invoice!()
      old_token = InvoiceLinks.token(invoice)
      other_token = InvoiceLinks.token(other)

      assert {:ok, revoked} = Billing.revoke_invoice_pay_links(invoice)

      assert Billing.get_invoice_by_pay_token(old_token) == nil
      assert %Invoice{} = Billing.get_invoice_by_pay_token(other_token)

      new_token = InvoiceLinks.token(revoked)
      assert new_token != old_token
      assert %Invoice{uuid: uuid} = Billing.get_invoice_by_pay_token(new_token)
      assert uuid == invoice.uuid

      assert {:error, :invoice_not_found} =
               Billing.revoke_invoice_pay_links(%Invoice{uuid: Ecto.UUID.generate()})
    end

    test "the URL is absolute and carries the token" do
      invoice = guest_invoice!()
      url = Billing.invoice_pay_url(invoice)

      assert url =~ "/billing/pay/"
      assert String.starts_with?(url, "http")
    end
  end

  describe "the payment page" do
    setup do
      Settings.update_setting("billing_stripe_enabled", "true")
      Settings.update_setting("billing_stripe_secret_key", "sk_test_123")

      Application.put_env(:phoenix_kit_billing, :stripe_req_options, plug: {Req.Test, __MODULE__})

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_billing, :stripe_req_options)
        Settings.update_setting("billing_stripe_enabled", "false")
        Settings.update_setting("billing_stripe_secret_key", "")
      end)

      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:stripe, conn.request_path, URI.decode_query(body)})

        Req.Test.json(conn, %{
          "id" => "cs_guest",
          "url" => "https://checkout.stripe.test/guest",
          "expires_at" => System.os_time(:second) + 3600
        })
      end)

      :ok
    end

    test "shows the invoice and pays it through the provider's checkout", %{conn: conn} do
      invoice = guest_invoice!()
      path = "/billing/pay/" <> InvoiceLinks.token(invoice)

      {:ok, view, html} = live(conn, path)
      assert html =~ invoice.invoice_number
      assert html =~ "Yoga class"
      assert html =~ "Ann Guest"
      assert has_element?(view, "#billing-guest-invoice-due")

      assert {:error, {:redirect, %{to: "https://checkout.stripe.test/guest"}}} =
               view |> element("button", "Stripe") |> render_click()

      assert_received {:stripe, "/v1/checkout/sessions", params}
      assert params["customer_email"] == "ann@example.com"
      assert params["success_url"] =~ "/billing/pay/"
      assert params["success_url"] =~ "checkout=done"

      stored = Repo.get!(Invoice, invoice.uuid)
      assert stored.metadata["checkout"]["provider_session_id"] == "cs_guest"
    end

    test "updates live when the payment lands", %{conn: conn} do
      invoice = guest_invoice!()

      {:ok, view, _html} =
        live(conn, "/billing/pay/" <> InvoiceLinks.token(invoice) <> "?checkout=done")

      assert render(view) =~ "being confirmed"

      {:ok, _} =
        Billing.record_payment(
          invoice,
          %{amount: "15.00", payment_method: "stripe", provider_transaction_id: "pi_g"},
          nil
        )

      assert render(view) =~ "This invoice is paid"
      refute has_element?(view, "button", "Stripe")
    end

    test "a void invoice offers no payment", %{conn: conn} do
      invoice = guest_invoice!()
      {:ok, _} = Billing.void_invoice(invoice)

      {:ok, view, html} = live(conn, "/billing/pay/" <> InvoiceLinks.token(invoice))
      assert html =~ "cancelled and cannot be paid"
      refute has_element?(view, "button", "Stripe")
    end

    test "a bad token shows an error and nothing else", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/billing/pay/not-a-token")
      assert html =~ "invalid or has expired"
    end

    test "a provider that is not available is refused", %{conn: conn} do
      invoice = guest_invoice!()
      {:ok, view, _html} = live(conn, "/billing/pay/" <> InvoiceLinks.token(invoice))

      assert render_click(view, "pay", %{"provider" => "paypal"}) =~ "not available"
      refute_received {:stripe, _, _}
    end
  end

  describe "a guest invoice paid by webhook" do
    setup do
      Process.register(self(), :guest_invoices_test)
      Application.put_env(:phoenix_kit_billing, :invoice_event_handlers, [PaidHandler])
      on_exit(fn -> Application.delete_env(:phoenix_kit_billing, :invoice_event_handlers) end)
      start_supervised!({Oban, repo: Repo, testing: :manual})
      :ok
    end

    test "enqueues the durable :paid event and announces it on the invoice's topic" do
      booking_uuid = Ecto.UUID.generate()
      invoice = guest_invoice!(%{metadata: %{"booking_uuid" => booking_uuid}})
      Events.subscribe_invoice(invoice.uuid)

      payload = %{
        "id" => "evt_#{System.unique_integer([:positive])}",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "id" => "cs_1",
            "mode" => "payment",
            "payment_status" => "paid",
            "payment_intent" => "pi_guest",
            "amount_total" => 1500,
            "currency" => "eur",
            "metadata" => %{"invoice_uuid" => invoice.uuid}
          }
        }
      }

      {:ok, event} = Providers.handle_webhook_event(:stripe, payload)
      assert {:ok, %Invoice{status: "paid"}} = WebhookProcessor.process(event)

      assert_received {:invoice_paid, %Invoice{uuid: uuid}}
      assert uuid == invoice.uuid
      assert_received {:transaction_created, _}

      assert_enqueued(
        worker: InvoiceEventWorker,
        args: %{
          "event" => "paid",
          "invoice_uuid" => invoice.uuid,
          "handler" => inspect(PaidHandler)
        }
      )

      assert %{success: 1} = Oban.drain_queue(queue: :billing)
      assert_received {:paid, ^uuid, ^booking_uuid}
    end
  end

  describe "admin invoice page" do
    test "shows the payment link for a payable invoice", %{conn: conn} do
      invoice = guest_invoice!()
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
      assert has_element?(view, "#invoice-pay-link")
      assert render(view) =~ "/billing/pay/"
    end

    test "New link revokes the link shown so far", %{conn: conn} do
      invoice = guest_invoice!()
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
      old_token = shown_token(html)
      assert %Invoice{} = Billing.get_invoice_by_pay_token(old_token)

      html = view |> element("#invoice-pay-link-revoke") |> render_click()

      assert Billing.get_invoice_by_pay_token(old_token) == nil
      assert %Invoice{uuid: uuid} = html |> shown_token() |> Billing.get_invoice_by_pay_token()
      assert uuid == invoice.uuid
    end

    defp shown_token(html) do
      [_, token] = Regex.run(~r{/billing/pay/([^"?]+)"}, html)
      token
    end
  end
end
