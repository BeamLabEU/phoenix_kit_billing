defmodule PhoenixKitBilling.Regression.SendEmailAvailabilityThroughSendInvoiceTest do
  @moduledoc """
  B003 round 2 regression: `do_send_invoice/3` (private, reached only
  through the public `send_invoice/2` — exactly the path
  `invoice_detail/actions.ex`'s `send_invoice/1` handler uses) used to
  call `send_invoice_email/2` and DISCARD its return value entirely,
  then unconditionally return `{:ok, updated_invoice}`. Combined with
  round 2's own warn-once-per-boot log dedup, this meant: on an install
  where phoenix_kit_emails is permanently absent (not transient — the
  owner's actual, ongoing configuration), the FIRST invoice sent that
  boot got a log line, and EVERY SUBSEQUENT one got nothing at all — no
  log (deduplicated) AND a caller-visible `{:ok, invoice}` indistinguishable
  from a real send. The exact defect this contract exists to fix, back
  for 99% of calls on the only kind of install where it matters.

  Fixed by having `do_send_invoice/3` (and its three siblings) carry the
  email outcome through as a third tuple element -
  `{:ok, updated_invoice, email_result}` - instead of discarding it. The
  record-level operation (status change, send-history entry) already
  committed by that point regardless of the email outcome, so it can't
  honestly become part of an `{:error, _}` return; the email result is
  additional information alongside the success, not a replacement for
  it. This is now the sole thing that has to hold for every call,
  independent of whatever the log is doing: the *log* can stay
  deduplicated (a supplementary breadcrumb), but the *return value*
  cannot be, ever - that was round 2's actual mistake, conflating "log
  noise is fine to reduce" with "the caller's own signal is fine to
  reduce," when only the first one was.
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

  defp fresh_invoice(user) do
    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    assert invoice.status == "draft"
    invoice
  end

  test "the second of two consecutive sends does not look successful just because the log went quiet" do
    user1 = user_fixture()
    user2 = user_fixture()
    invoice1 = fresh_invoice(user1)
    invoice2 = fresh_invoice(user2)

    log =
      capture_log(fn ->
        # First call: this is the one round 2's "once per boot" log fires
        # for.
        assert {:ok, %{status: "sent"}, {:error, :emails_module_not_installed}} =
                 Billing.send_invoice(invoice1, to_email: user1.email, send_email: true)

        # Second call, a DIFFERENT invoice: the regression was that this
        # one silently reported success. It must not - regardless of
        # whether the log repeats, which it deliberately does not (see
        # the log assertions below).
        assert {:ok, %{status: "sent"}, {:error, :emails_module_not_installed}} =
                 Billing.send_invoice(invoice2, to_email: user2.email, send_email: true)
      end)

    # The log dedup is real and intentional (see send_email_if_available/4)
    # - exactly one line, carrying invoice1's own uuid, not invoice2's.
    # The point of this test is that the RETURN VALUE above already
    # proved both calls are addressable without needing this log at all.
    assert Enum.count(String.split(log, "email not sent")) - 1 == 1
    assert log =~ invoice1.uuid
    refute log =~ invoice2.uuid
  end

  test "send_invoice/2's real send_email? branch reaches send_email_if_available/4" do
    user = user_fixture()
    invoice = fresh_invoice(user)

    log =
      capture_log(fn ->
        result = Billing.send_invoice(invoice, to_email: user.email, send_email: true)

        assert {:ok, %{status: "sent"}, {:error, :emails_module_not_installed}} = result
      end)

    assert log =~ "email not sent"
    refute log =~ user.email
  end

  test "send_invoice/2 with send_email: false never reaches it at all" do
    user = user_fixture()
    invoice = fresh_invoice(user)

    log =
      capture_log(fn ->
        assert {:ok, %{status: "sent"}, :skipped} =
                 Billing.send_invoice(invoice, to_email: user.email, send_email: false)
      end)

    refute log =~ "email not sent"
  end
end
