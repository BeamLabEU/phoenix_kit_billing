defmodule PhoenixKit.Modules.Emails do
  @moduledoc """
  Test-only stand-in for the `phoenix_kit_emails` sibling package's
  namespace module — deliberately has NO nested `Templates` module.

  Reproduces a real, reachable configuration: `phoenix_kit_emails` pinned
  to a release that renamed or dropped `Templates.send_email/4`, or a
  host that only partially installed it. `Code.ensure_loaded?/1` on
  `PhoenixKit.Modules.Emails` alone (the pre-fix check in
  `send_email_if_available/4`) can't tell this apart from a fully
  working install — only checking `Templates` itself, the module
  actually `apply/3`'d, can.
  """
end

defmodule PhoenixKitBilling.Regression.SendEmailModuleCheckTest do
  @moduledoc """
  `send_email_if_available/4` (`lib/phoenix_kit_billing.ex`) used to gate
  on `Code.ensure_loaded?(PhoenixKit.Modules.Emails)` — the sibling
  package's namespace module — then unconditionally `apply/3` a function
  on `PhoenixKit.Modules.Emails.Templates`, a DIFFERENT module one level
  down. The two load independently. With the namespace module present
  but `Templates` absent (or missing `send_email/4`), the old code took
  the "available" branch and `apply/3` raised `UndefinedFunctionError` —
  the exact case this file's stub `PhoenixKit.Modules.Emails` (defined
  above, deliberately empty) reproduces.

  Also covers the more common case, where phoenix_kit_emails isn't
  installed at all — true in this test environment already (see the
  "[ModuleRegistry] ... module 'emails' is not registered" warning any
  test run prints) — confirming the same distinguishable, logged failure
  either way, not an exception in one case and silent success in the
  other.
  """

  use PhoenixKitBilling.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Users.Auth
  alias PhoenixKitBilling, as: Billing

  defp user_fixture do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "send-email-module-check-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    user
  end

  test "Emails present but Templates absent: no exception, a logged and distinguishable error" do
    assert Code.ensure_loaded?(PhoenixKit.Modules.Emails)
    refute Code.ensure_loaded?(PhoenixKit.Modules.Emails.Templates)

    user = user_fixture()

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    log =
      capture_log(fn ->
        result = Billing.send_invoice_email(invoice, to_email: user.email, send_email: false)
        assert {:error, :emails_module_not_installed} = result
      end)

    assert log =~ "billing_invoice email not sent"
    refute log =~ user.email
  end

  test "Emails entirely absent: the same distinguishable error, logged" do
    user = user_fixture()

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    log =
      capture_log(fn ->
        result = Billing.send_receipt_email(invoice, to_email: user.email, send_email: false)
        assert {:error, :emails_module_not_installed} = result
      end)

    assert log =~ "billing_receipt email not sent"
    refute log =~ user.email
  end
end
