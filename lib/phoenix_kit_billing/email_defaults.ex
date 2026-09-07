defmodule PhoenixKitBilling.EmailDefaults do
  @moduledoc """
  The content billing's four financial emails fall back to.

  Until now these lived in `phoenix_kit_emails`, seeded into the
  `phoenix_kit_email_templates` table — so the emails package hardcoded another
  module's copy, and billing could not send at all without it installed. That
  table is being retired; this is where the content lives instead.

  Handed to `PhoenixKit.Mailer.send_from_template/4` as `:defaults`, which
  resolves in order: an active database template, then a host override file for
  the recipient's locale, then this. **A host that customized one of these
  templates keeps its customization** — the database still wins — so adopting
  this changes nothing for an existing install.

  ## Why these are functions, not a map

  `send_from_template/4` evaluates a zero-arity `:defaults` *inside the
  recipient's locale*. A map would have been evaluated in whatever locale the
  caller happened to be in — which, on a background job sending an invoice, is
  nobody's.

  ## HTML is deliberately absent

  The shipped templates also carried an HTML body: roughly 200 lines each of
  inline markup, with the header and footer chrome copy-pasted between them.
  Re-homing that here would bake the duplication into a second package
  immediately before the shared layout layer is built to remove it.

  Consequence, and it is a real one: **a host loses the HTML billing emails
  when the templates table is dropped**, keeping the plain-text ones. The
  layout layer has to land before that drop. Until then nothing changes,
  because the database row still wins.
  """

  use Gettext, backend: PhoenixKitBilling.Gettext

  @templates ~w(billing_invoice billing_receipt billing_credit_note billing_payment_confirmation)

  @doc "The template names this module supplies defaults for."
  @spec template_names() :: [String.t()]
  def template_names, do: @templates

  @doc """
  A zero-arity function returning the default content for `name`, or `nil` when
  this module has nothing to say about that name.
  """
  @spec defaults_for(String.t()) :: (-> %{subject: String.t(), text: String.t()}) | nil
  def defaults_for(name) when name in @templates, do: fn -> for_template(name) end
  def defaults_for(_name), do: nil

  def for_template("billing_invoice") do
    %{
      subject: gettext("Invoice {{invoice_number}} - {{company_name}}"),
      text:
        gettext("""
        =============================================
        INVOICE {{invoice_number}}
        =============================================

        Bill To: {{user_name}}
        Email: {{user_email}}

        Invoice Date: {{invoice_date}}
        Due Date: {{due_date}}
        Currency: {{currency}}

        ---------------------------------------------
        LINE ITEMS
        ---------------------------------------------
        {{line_items_text}}

        ---------------------------------------------
        SUMMARY
        ---------------------------------------------
        Subtotal:    {{subtotal}} {{currency}}
        Tax:         {{tax_amount}} {{currency}}
        ---------------------------------------------
        TOTAL:       {{total}} {{currency}}
        ---------------------------------------------

        PAYMENT DUE: {{due_date}}
        {{payment_terms}}

        ---------------------------------------------
        BANK TRANSFER DETAILS
        ---------------------------------------------
        Bank:        {{bank_name}}
        IBAN:        {{bank_iban}}
        SWIFT/BIC:   {{bank_swift}}
        Reference:   {{invoice_number}}

        ---------------------------------------------
        View invoice online: {{invoice_url}}

        =============================================
        {{company_name}}
        {{company_address}}
        VAT: {{company_vat}}
        =============================================

        If you have any questions about this invoice, please contact us.
        """)
    }
  end

  def for_template("billing_receipt") do
    %{
      subject: gettext("Receipt {{receipt_number}} - {{company_name}}"),
      text:
        gettext("""
        =============================================
        RECEIPT {{receipt_number}}
        =============================================
        STATUS: PAID

        Thank you for your payment!
        Your payment has been successfully processed.

        ---------------------------------------------
        RECEIVED FROM
        ---------------------------------------------
        Name: {{user_name}}
        Email: {{user_email}}

        Payment Date: {{payment_date}}
        Invoice: {{invoice_number}}
        Currency: {{currency}}

        ---------------------------------------------
        LINE ITEMS
        ---------------------------------------------
        {{line_items_text}}

        ---------------------------------------------
        SUMMARY
        ---------------------------------------------
        Subtotal:    {{subtotal}} {{currency}}
        Tax:         {{tax_amount}} {{currency}}
        ---------------------------------------------
        TOTAL PAID:  {{paid_amount}} {{currency}}
        ---------------------------------------------

        PAYMENT CONFIRMED: {{payment_date}}

        ---------------------------------------------
        View receipt online: {{receipt_url}}

        =============================================
        {{company_name}}
        {{company_address}}
        VAT: {{company_vat}}
        =============================================

        Thank you for your business.
        If you have any questions, please contact us.
        """)
    }
  end

  def for_template("billing_credit_note") do
    %{
      subject: gettext("Credit Note {{credit_note_number}} - Refund Issued - {{company_name}}"),
      text:
        gettext("""
        =============================================
        CREDIT NOTE {{credit_note_number}}
        =============================================
        STATUS: REFUND ISSUED

        A refund has been processed for your account.

        REFUND AMOUNT: {{refund_amount}} {{currency}}

        ---------------------------------------------
        ISSUED BY (PAYER)
        ---------------------------------------------
        {{company_name}}
        {{company_address}}
        VAT: {{company_vat}}

        ---------------------------------------------
        ISSUED TO (PAYEE)
        ---------------------------------------------
        Name: {{user_name}}
        Email: {{user_email}}

        ---------------------------------------------
        REFUND DETAILS
        ---------------------------------------------
        Credit Note #:     {{credit_note_number}}
        Refund Date:       {{refund_date}}
        Refund Amount:     {{refund_amount}} {{currency}}
        Original Invoice:  {{invoice_number}}
        Transaction #:     {{transaction_number}}

        ---------------------------------------------
        REASON FOR REFUND
        ---------------------------------------------
        {{refund_reason}}

        ---------------------------------------------
        View credit note online: {{credit_note_url}}

        The refund will be processed to your original payment method.
        Please allow 5-10 business days for the refund to appear in your account.

        =============================================
        {{company_name}}
        {{company_address}}
        VAT: {{company_vat}}
        =============================================

        If you have any questions about this refund, please contact us.
        """)
    }
  end

  def for_template("billing_payment_confirmation") do
    %{
      subject: gettext("Payment Received - {{confirmation_number}} - {{company_name}}"),
      text:
        gettext("""
        =============================================
        PAYMENT CONFIRMATION {{confirmation_number}}
        =============================================
        STATUS: PAYMENT RECEIVED

        Thank you for your payment.

        PAYMENT AMOUNT: {{payment_amount}} {{currency}}

        ---------------------------------------------
        PAYMENT DETAILS
        ---------------------------------------------
        Confirmation #:    {{confirmation_number}}
        Invoice #:         {{invoice_number}}
        Payment Date:      {{payment_date}}
        Payment Method:    {{payment_method}}
        Transaction #:     {{transaction_number}}

        ---------------------------------------------
        BALANCE SUMMARY
        ---------------------------------------------
        Invoice Total:     {{invoice_total}} {{currency}}
        Total Paid:        {{total_paid}} {{currency}}
        Remaining:         {{remaining_balance}} {{currency}}

        ---------------------------------------------
        View payment confirmation online: {{payment_url}}

        =============================================
        {{company_name}}
        {{company_address}}
        =============================================

        Thank you for your business. If you have any questions, please contact us.
        """)
    }
  end
end
