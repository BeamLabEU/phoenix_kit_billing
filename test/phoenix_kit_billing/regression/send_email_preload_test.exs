defmodule PhoenixKitBilling.Regression.SendEmailPreloadTest do
  @moduledoc """
  `do_send_invoice/3`, `send_invoice_email/2`, `do_send_receipt/2`,
  `send_receipt_email/2`, `do_send_credit_note/3`, `send_credit_note_email/3`,
  `do_send_payment_confirmation/3`, and `send_payment_confirmation_email/3`
  all carried a comment saying "Preload user if not loaded" while the code
  actually preloaded only `:order`, then read `invoice.user.email` a few
  lines down. Every current `web/` call site happens to pass an invoice
  that already has `:user` preloaded from its own LiveView mount, which
  masked this: `Ecto.Repo.preload/2` only touches the associations it's
  asked for and leaves everything else on the struct untouched, so the
  already-loaded `:user` survived `ensure_preloaded(invoice, [:order])`
  unharmed. But these are public `PhoenixKitBilling` API functions — any
  caller passing a bare `Billing.get_invoice/1` (default preload is
  `[:order]` only) hits the same `KeyError` the four print views did.

  This exercises `send_invoice_email/2` directly against an invoice
  fetched with the bare default preload, bypassing every `web/` call site
  entirely, so the assertion can't be satisfied by chance the way a
  LiveView-mounted fixture would.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitBilling, as: Billing

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "send-email-preload-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    user
  end

  test "send_invoice_email/2 doesn't crash on an invoice fetched without :user preloaded" do
    user = user_fixture()

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    # `Billing.get_invoice/1` (no opts) defaults to `preload: [:order]` —
    # `:user` is deliberately left unloaded here, the same shape a bare
    # public-API caller (not a LiveView mount) would produce.
    under_preloaded_invoice = Billing.get_invoice(invoice.uuid)
    assert %Ecto.Association.NotLoaded{} = under_preloaded_invoice.user

    # No `:to_email` opt — forces the function down its own
    # `invoice.user && invoice.user.email` fallback path instead of
    # short-circuiting on the caller-supplied address.
    result = Billing.send_invoice_email(under_preloaded_invoice, send_email: false)

    refute match?({:error, :no_recipient_email}, result)
  end
end
