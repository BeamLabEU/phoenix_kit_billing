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

  Each test below exercises one public `send_*_email/2,3` function directly
  against an invoice fetched with the bare default preload, bypassing every
  `web/` call site entirely, so the assertion can't be satisfied by chance
  the way a LiveView-mounted fixture would.

  The four private `do_send_*/2,3` wrappers (`do_send_invoice`,
  `do_send_receipt`, `do_send_credit_note`, `do_send_payment_confirmation`)
  are deliberately NOT covered here: they only ever run after their public
  caller (`send_invoice/2`, `send_receipt/2`, `send_credit_note/3`,
  `send_payment_confirmation/3`) has already fetched or been handed an
  invoice — by construction there is no code path that reaches a
  `do_send_*` with `:user` unloaded that doesn't already pass through one
  of the four functions tested here first. A test built to reach a
  `do_send_*` directly would have to hand-construct that "impossible"
  state itself, which proves nothing about real callers — the coverage
  that matters is at the public boundary, not the private implementation
  detail behind it.
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

  defp invoice_fixture(user) do
    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    invoice
  end

  # `record_payment/3` only accepts a "sendable" invoice out of "draft" —
  # `:to_email` is passed explicitly so this fixture doesn't depend on
  # `send_invoice/2`'s own (already-fixed, but not what these tests are
  # about) preload handling of `invoice.user`.
  defp sent_invoice_fixture(user) do
    invoice = invoice_fixture(user)
    {:ok, invoice} = Billing.send_invoice(invoice, to_email: user.email, send_email: false)
    invoice
  end

  # `Billing.get_invoice/1` (no opts) defaults to `preload: [:order]` —
  # `:user` is deliberately left unloaded here, the same shape a bare
  # public-API caller (not a LiveView mount) would produce.
  defp under_preloaded(invoice) do
    reloaded = Billing.get_invoice(invoice.uuid)
    assert %Ecto.Association.NotLoaded{} = reloaded.user
    reloaded
  end

  test "send_invoice_email/2 doesn't crash on an invoice fetched without :user preloaded" do
    invoice = user_fixture() |> invoice_fixture() |> under_preloaded()

    # No `:to_email` opt — forces the function down its own
    # `invoice.user && invoice.user.email` fallback path instead of
    # short-circuiting on the caller-supplied address.
    result = Billing.send_invoice_email(invoice, send_email: false)

    # Asserts the concrete success value, not just "not this one error" —
    # `send_email_if_available/4` returns bare `:ok` when
    # `PhoenixKit.Modules.Emails` isn't loaded (true in this test env, and
    # on any host without the emails package installed); a looser
    # assertion here would pass on an unrelated failure just as easily as
    # on success.
    assert :ok = result
  end

  test "send_receipt_email/2 doesn't crash on an invoice fetched without :user preloaded" do
    invoice = user_fixture() |> invoice_fixture() |> under_preloaded()

    result = Billing.send_receipt_email(invoice, send_email: false)

    assert :ok = result
  end

  test "send_credit_note_email/3 doesn't crash on an invoice fetched without :user preloaded" do
    user = user_fixture()
    invoice = sent_invoice_fixture(user)
    {:ok, _payment} = Billing.record_payment(invoice, %{amount: "100.00"}, nil)
    paid_invoice = Billing.get_invoice!(invoice.uuid)

    {:ok, refund} =
      Billing.record_refund(paid_invoice, %{amount: "40.00", description: "damaged"}, nil)

    result = Billing.send_credit_note_email(under_preloaded(invoice), refund, send_email: false)

    assert :ok = result
  end

  test "send_payment_confirmation_email/3 doesn't crash on an invoice fetched without :user preloaded" do
    user = user_fixture()
    invoice = sent_invoice_fixture(user)
    {:ok, payment} = Billing.record_payment(invoice, %{amount: "25.00"}, nil)

    result =
      Billing.send_payment_confirmation_email(under_preloaded(invoice), payment,
        send_email: false
      )

    assert :ok = result
  end
end
