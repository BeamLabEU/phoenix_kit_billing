defmodule PhoenixKitBilling.Web.CSPMarkupTest do
  @moduledoc """
  The buttons that used to carry an inline `onclick` now name what they do
  with a `data-pkb-*` attribute, which `priv/static/assets/phoenix_kit_billing.js`
  acts on (its own tests: `test/js/`). A nonce-based Content-Security-Policy
  blocks an inline handler; these pin the rendered markup.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    {:ok, conn: put_test_scope(conn, scope), user: user}
  end

  test "the print button asks for a print with data-pkb-print", %{conn: conn, user: user} do
    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    {:ok, invoice, _} =
      Billing.send_invoice(invoice, to_email: "customer@example.com", send_email: false)

    {:ok, view, html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}/print")

    assert has_element?(view, "button#print-button[data-pkb-print]")
    refute html =~ "onclick"
    refute html =~ "window.print"
  end

  test "each provider's copy button carries its webhook URL in data-pkb-copy", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/settings/billing/providers")

    copied =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("button[data-pkb-copy]")
      |> LazyHTML.attribute("data-pkb-copy")

    for provider <- ~w(stripe paypal razorpay everypay) do
      assert Enum.any?(copied, &String.ends_with?(&1, "/webhooks/billing/#{provider}")),
             "no copy button for #{provider} in #{inspect(copied)}"
    end

    assert length(copied) == 4
    refute html =~ "onclick"
    refute html =~ "clipboard.writeText"
  end
end
