defmodule PhoenixKitBilling.Regression.SendEmailAvailabilityThroughSendInvoiceTest do
  @moduledoc """
  `send_email_module_check_test.exs` and `send_email_preload_test.exs`
  both call `send_invoice_email/2` directly — proof the fix works at
  that boundary, but not proof the *production* call path (a LiveView
  calling the public, gated `send_invoice/2`, which conditionally calls
  `send_invoice_email/2` internally, exactly the way
  `invoice_detail/actions.ex`'s `send_invoice/1` handler does) actually
  reaches it too. This test goes through that real path instead.

  One thing this deliberately does NOT claim: `do_send_invoice/3`
  (private, reached only through `send_invoice/2`) calls
  `send_invoice_email/2` but discards its return value — win or lose,
  `send_invoice/2` itself still returns `{:ok, updated_invoice}`. That's
  a real, separate gap from the one this contract (B003) fixes: the
  *email-unavailable* condition is now always logged and always
  returned as `{:error, :emails_module_not_installed}` from
  `send_invoice_email/2` itself, but a caller of the outer
  `send_invoice/2` still can't see that from ITS return value - only
  from the log this test asserts on. Flagged, not fixed here; fixing it
  would mean deciding whether `send_invoice/2`'s own success should
  depend on email delivery, which is a bigger, separate call.
  """

  use PhoenixKitBilling.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Users.Auth
  alias PhoenixKitBilling, as: Billing

  setup do
    Billing.reset_emails_unavailable_warning!()
    :ok
  end

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "send-invoice-real-path-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    user
  end

  test "send_invoice/2's real send_email? branch reaches send_email_if_available/4" do
    user = user_fixture()

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    assert invoice.status == "draft"

    log =
      capture_log(fn ->
        result = Billing.send_invoice(invoice, to_email: user.email, send_email: true)

        # The gap this test documents, not fixes: send_invoice/2 reports
        # success regardless of whether the email underneath it actually
        # went anywhere.
        assert {:ok, %{status: "sent"}} = result
      end)

    assert log =~ "billing_invoice email not sent"
    refute log =~ user.email
  end

  test "send_invoice/2 with send_email: false never reaches it at all" do
    user = user_fixture()

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    log =
      capture_log(fn ->
        assert {:ok, %{status: "sent"}} =
                 Billing.send_invoice(invoice, to_email: user.email, send_email: false)
      end)

    refute log =~ "email not sent"
  end
end
