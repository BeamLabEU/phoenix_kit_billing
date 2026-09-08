defmodule PhoenixKitBilling.EmailDefaultsTest do
  @moduledoc """
  The content billing's four financial emails fall back to once the
  `phoenix_kit_email_templates` table is retired.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBilling.EmailDefaults

  # Every placeholder each template uses. These must be supplied by the
  # matching `build_*_email_variables/3` in `PhoenixKitBilling`, or the email
  # goes out with a literal `{{placeholder}}` in it — the substitution leaves
  # an unbound one visible rather than blanking it, precisely so a mismatch is
  # obvious instead of silent. Adding a placeholder to a template means adding
  # it to the builder, and this list is what makes you notice.
  @placeholders %{
    "billing_invoice" =>
      ~w(bank_iban bank_name bank_swift company_address company_name company_vat currency
         due_date invoice_date invoice_number invoice_url line_items_text payment_terms
         subtotal tax_amount total user_email user_name),
    "billing_receipt" =>
      ~w(company_address company_name company_vat currency invoice_number line_items_text
         paid_amount payment_date receipt_number receipt_url subtotal tax_amount user_email
         user_name),
    "billing_credit_note" =>
      ~w(company_address company_name company_vat credit_note_number credit_note_url currency
         invoice_number refund_amount refund_date refund_reason transaction_number user_email
         user_name),
    "billing_payment_confirmation" =>
      ~w(company_address company_name confirmation_number currency invoice_number invoice_total
         payment_amount payment_date payment_method payment_url remaining_balance total_paid
         transaction_number)
  }

  defp placeholders(text) do
    ~r/\{\{(\w+)\}\}/
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  describe "defaults_for/1" do
    test "answers every template billing sends" do
      assert EmailDefaults.template_names() == [
               "billing_invoice",
               "billing_receipt",
               "billing_credit_note",
               "billing_payment_confirmation"
             ]

      for name <- EmailDefaults.template_names() do
        assert is_function(EmailDefaults.defaults_for(name), 0), "no defaults for #{name}"
      end
    end

    test "answers nil for a name it knows nothing about" do
      # `send_from_template/4` treats a nil default as "nothing to fall back
      # to", which is the honest answer for someone else's template.
      assert EmailDefaults.defaults_for("register") == nil
      assert EmailDefaults.defaults_for("") == nil
    end

    test "is a function, so it is evaluated in the recipient's locale" do
      # A map would already have been evaluated in whatever locale the caller
      # happened to be in — on a background job sending an invoice, nobody's.
      assert is_function(EmailDefaults.defaults_for("billing_invoice"), 0)
    end
  end

  describe "content" do
    test "every template supplies a non-empty subject and text" do
      for name <- EmailDefaults.template_names() do
        content = EmailDefaults.defaults_for(name).()

        assert is_binary(content.subject) and content.subject != "", "empty subject: #{name}"
        assert is_binary(content.text) and content.text != "", "empty text: #{name}"
      end
    end

    test "html is absent, deliberately" do
      # The shipped HTML bodies are the duplicated chrome the shared layout
      # layer exists to remove; re-homing them here would bake that duplication
      # into a second package. See the moduledoc — this is a known gap that
      # must close before the templates table is dropped.
      for name <- EmailDefaults.template_names() do
        refute Map.has_key?(EmailDefaults.defaults_for(name).(), :html)
      end
    end

    test "each template uses exactly the placeholders billing supplies" do
      for {name, expected} <- @placeholders do
        content = EmailDefaults.defaults_for(name).()
        actual = placeholders(content.subject <> content.text)

        assert actual == Enum.sort(expected),
               "#{name} placeholders drifted from what build_*_email_variables/3 supplies.\n" <>
                 "added: #{inspect(actual -- Enum.sort(expected))}\n" <>
                 "removed: #{inspect(Enum.sort(expected) -- actual)}"
      end
    end
  end
end
