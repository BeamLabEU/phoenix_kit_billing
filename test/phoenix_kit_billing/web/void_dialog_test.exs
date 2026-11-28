defmodule PhoenixKitBilling.Web.VoidDialogTest do
  @moduledoc """
  The admin void dialog when the payment provider cannot be reached to close the
  invoice's open checkout: the void is refused, and the dialog then offers
  "Void anyway" (`void_invoice/3` with `close_checkout: false`).
  """

  use PhoenixKitBilling.LiveCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Providers.Types.CheckoutSession
  alias PhoenixKitBilling.Test.Repo

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

    # Stripe is down.
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{"error" => %{"message" => "boom", "type" => "api_error"}})
    end)

    {:ok, invoice} =
      Billing.create_invoice(fixture_user(), %{total: Decimal.new("20.00"), currency: "EUR"})

    {:ok, invoice, _} = Billing.send_invoice(invoice, send_email: false)

    :ok =
      Billing.record_checkout_session(invoice, :stripe, %CheckoutSession{
        id: "cs_open",
        url: "https://checkout.stripe.test/cs_open",
        provider: :stripe,
        expires_at: DateTime.add(DateTime.utc_now(), 3600)
      })

    {:ok, conn: put_test_scope(conn, fake_scope()), invoice: invoice}
  end

  test "a refused void offers Void anyway, which voids", %{conn: conn, invoice: invoice} do
    {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
    view |> element("#void-invoice-button") |> render_click()
    refute has_element?(view, "#void-anyway-button")

    capture_log(fn -> view |> form("#void-invoice-form") |> render_submit() end)

    assert Repo.get!(Invoice, invoice.uuid).status == "sent"
    assert has_element?(view, "#void-checkout-unreachable")
    assert has_element?(view, "#void-anyway-button")

    view |> form("#void-invoice-form") |> render_submit(%{"void_anyway" => "true"})

    assert Repo.get!(Invoice, invoice.uuid).status == "void"
  end

  test "void_anyway is not honoured before the provider refused", %{conn: conn, invoice: invoice} do
    {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")
    view |> element("#void-invoice-button") |> render_click()

    capture_log(fn ->
      view |> form("#void-invoice-form") |> render_submit(%{"void_anyway" => "true"})
    end)

    assert Repo.get!(Invoice, invoice.uuid).status == "sent"
  end
end
