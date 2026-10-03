defmodule PhoenixKitBilling.Integration.EmailSendOptsTest do
  @moduledoc """
  Every `send_*_email` hands `PhoenixKit.Modules.Emails.Templates.send_email/4`
  the options `PhoenixKitBilling.email_send_opts/4` builds — billing's
  defaults, `layout: "billing"` and the customer's locale.

  `phoenix_kit_emails` is not installed in this suite (and
  `regression/send_email_module_check_test.exs` relies on that), so each test
  compiles a stand-in `Templates` that reports what it was called with, and
  removes it again on exit. The suite is synchronous: ExUnit runs no other
  test while this one has the stand-in loaded.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.EmailDefaults

  @stub PhoenixKit.Modules.Emails.Templates

  setup do
    refute Code.ensure_loaded?(@stub),
           "a real #{inspect(@stub)} is loaded; this test would replace it"

    :persistent_term.put({__MODULE__, :pid}, self())

    Code.compile_string("""
    defmodule PhoenixKit.Modules.Emails.Templates do
      def send_email(template, email, variables, opts) do
        pid = :persistent_term.get({#{inspect(__MODULE__)}, :pid})
        send(pid, {:send_email, template, email, variables, opts})
        {:ok, :stubbed}
      end
    end
    """)

    on_exit(fn ->
      :code.purge(@stub)
      :code.delete(@stub)
      :code.purge(@stub)
      :persistent_term.erase({__MODULE__, :pid})
    end)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "billing-send-opts-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    user = %{user | custom_fields: Map.put(user.custom_fields || %{}, "preferred_locale", "et")}

    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{
        subtotal: Decimal.new("30.00"),
        tax_amount: Decimal.new("0"),
        total: Decimal.new("30.00"),
        currency: "EUR",
        line_items: [
          %{"name" => "Widget", "quantity" => 2, "unit_price" => "15.00", "total" => "30.00"}
        ]
      })

    invoice = %{
      invoice
      | user: user,
        receipt_number: "RCP-1",
        paid_amount: Decimal.new("30.00")
    }

    transaction = %PhoenixKitBilling.Transaction{
      uuid: Ecto.UUID.generate(),
      transaction_number: "TXN-2026-0001",
      amount: Decimal.new("30.00"),
      currency: "EUR",
      payment_method: "bank",
      inserted_at: DateTime.utc_now()
    }

    %{user: user, invoice: invoice, transaction: transaction}
  end

  defp assert_billing_opts(template, user) do
    assert_received {:send_email, ^template, email, variables, opts}
    assert email == user.email

    expected = Billing.email_send_opts(template, variables, user, opts[:metadata])

    assert Keyword.delete(opts, :defaults) == Keyword.delete(expected, :defaults)
    assert opts[:layout] == "billing"
    assert opts[:locale] == "et"
    assert opts[:defaults].() == expected[:defaults].()
  end

  test "send_invoice_email/2", %{invoice: invoice, user: user} do
    assert {:ok, :stubbed} =
             Billing.send_invoice_email(invoice, invoice_url: "https://example.com/i")

    assert_billing_opts("billing_invoice", user)
  end

  test "send_receipt_email/2", %{invoice: invoice, user: user} do
    assert {:ok, :stubbed} = Billing.send_receipt_email(invoice, receipt_url: "")
    assert_billing_opts("billing_receipt", user)
  end

  test "send_credit_note_email/3", %{invoice: invoice, transaction: transaction, user: user} do
    assert {:ok, :stubbed} = Billing.send_credit_note_email(invoice, transaction)
    assert_billing_opts("billing_credit_note", user)
  end

  test "send_payment_confirmation_email/3",
       %{invoice: invoice, transaction: transaction, user: user} do
    assert {:ok, :stubbed} =
             Billing.send_payment_confirmation_email(invoice, transaction,
               payment_url: "https://example.com/p"
             )

    assert_billing_opts("billing_payment_confirmation", user)
  end

  test "a send without a link has no button in its defaults", %{invoice: invoice} do
    {:ok, :stubbed} = Billing.send_receipt_email(invoice)
    assert_received {:send_email, "billing_receipt", _email, _variables, opts}

    refute opts[:defaults].().markdown =~ "{{receipt_url}}"
    assert EmailDefaults.defaults_for("billing_receipt").().markdown =~ "{{receipt_url}}"
  end
end
