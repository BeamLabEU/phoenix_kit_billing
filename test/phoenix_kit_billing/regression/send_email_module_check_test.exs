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

  Compiling this stub makes `PhoenixKit.Modules.Emails` loaded for the
  *whole test run*, not just this file — every test below (and any other
  test that happens to run afterward) sees `Emails` as present. There is
  no test in this file for "the namespace module itself is entirely
  absent" as a result; that's genuinely covered elsewhere, by
  `send_email_preload_test.exs`, which defines no stub and runs in this
  same (stub-free otherwise) test environment.
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

  ## `send_email: false` does nothing here, deliberately

  `send_invoice_email/2` and `send_receipt_email/2` (called directly
  below) have no `:send_email` gate at all — that option only exists on
  their PUBLIC wrappers (`send_invoice/2`, `send_receipt/2`), which
  decide whether to call the `_email` function in the first place. Calls
  below intentionally go straight to the `_email` functions with no
  `send_email:` opt, so there's nothing to misread as short-circuiting
  the real branch. `real_production_path_test.exs`-style coverage
  through the gated public wrapper lives in
  `send_email_availability_through_send_invoice_test.exs`.

  ## Log is once-per-boot, not once-per-call

  `send_email_if_available/4` only logs the first time it hits this
  branch in the life of the BEAM (see its own comment) — every test here
  that asserts on log content calls
  `PhoenixKitBilling.reset_emails_unavailable_warning!/0` first so it
  isn't at the mercy of whichever test in the whole suite happens to run
  first.
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
        "email" => "send-email-module-check-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    user
  end

  test "Emails present, Templates absent: no exception, a logged and distinguishable error" do
    assert Code.ensure_loaded?(PhoenixKit.Modules.Emails)
    refute Code.ensure_loaded?(PhoenixKit.Modules.Emails.Templates)

    user = user_fixture()

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    log =
      capture_log(fn ->
        result = Billing.send_invoice_email(invoice, to_email: user.email)
        assert {:error, :emails_module_not_installed} = result
      end)

    assert log =~ "billing_invoice email not sent"
    refute log =~ user.email
  end

  test "the fix applies uniformly to a second public caller (send_receipt_email/2)" do
    user = user_fixture()

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    log =
      capture_log(fn ->
        result = Billing.send_receipt_email(invoice, to_email: user.email)
        assert {:error, :emails_module_not_installed} = result
      end)

    assert log =~ "billing_receipt email not sent"
    refute log =~ user.email
  end

  test "the log dedups per boot, but the return value never does — checked on every call, not just the log count" do
    user = user_fixture()

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

    log =
      capture_log(fn ->
        # Each iteration asserts the return value INSIDE the loop — a
        # test that only counted log lines after the fact (as an
        # earlier version of this test did) would have looked identical
        # whether every call correctly returned the distinguishable
        # error, or only the first one did and the rest silently
        # succeeded. That's exactly the round-2 regression this file's
        # sibling, send_email_availability_through_send_invoice_test.exs,
        # caught: do_send_invoice/3 discarded this same return value
        # one level up, so `send_invoice/2` kept reporting success on
        # every call after the first regardless of what
        # send_invoice_email/2 itself returned. This test only proves
        # send_invoice_email/2 is correct at its own boundary; that
        # other file proves the guarantee survives through the real
        # send_invoice/2 caller too.
        for _ <- 1..3 do
          assert {:error, :emails_module_not_installed} =
                   Billing.send_invoice_email(invoice, to_email: user.email)
        end
      end)

    # The log is the ONLY thing allowed to deduplicate.
    assert Enum.count(String.split(log, "email not sent")) - 1 == 1
  end
end
