defmodule PhoenixKitBilling.EmailDefaultsTest do
  @moduledoc """
  The content billing's four financial emails fall back to, the line-items
  fragments they carry, and their entries in core's email preview.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Billing, as: LegacyBilling
  alias PhoenixKit.Templates.Substitution
  alias PhoenixKitBilling.EmailDefaults

  # Every placeholder each template's subject and text use. These must be
  # supplied by the matching `build_*_email_variables` in `PhoenixKitBilling`,
  # or the email goes out with a literal `{{placeholder}}` in it — the
  # substitution leaves an unbound one visible rather than blanking it,
  # precisely so a mismatch is obvious instead of silent. Adding a placeholder
  # to a template means adding it to the builder, and this list is what makes
  # you notice. (`email_rendering_test.exs` checks the builders themselves.)
  @text_placeholders %{
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

  # The same for the Markdown body, which builds the HTML version.
  @markdown_placeholders %{
    "billing_invoice" =>
      ~w(bank_iban bank_name bank_swift company_address company_name company_vat currency
         due_date invoice_date invoice_number invoice_url line_items_table_html payment_terms
         subtotal tax_amount total user_name),
    "billing_receipt" =>
      ~w(company_address company_name company_vat currency invoice_number line_items_table_html
         paid_amount payment_date receipt_number receipt_url subtotal tax_amount user_name),
    "billing_credit_note" =>
      ~w(company_address company_name company_vat credit_note_number credit_note_url currency
         invoice_number refund_amount refund_date refund_reason transaction_number user_name),
    "billing_payment_confirmation" =>
      ~w(company_address company_name company_vat confirmation_number currency invoice_number
         invoice_total payment_amount payment_date payment_method payment_url remaining_balance
         total_paid transaction_number user_name)
  }

  @link_variables %{
    "billing_invoice" => "invoice_url",
    "billing_receipt" => "receipt_url",
    "billing_credit_note" => "credit_note_url",
    "billing_payment_confirmation" => "payment_url"
  }

  defp placeholders(text), do: text |> Substitution.variables() |> Enum.uniq() |> Enum.sort()

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
      assert EmailDefaults.defaults_for("register", %{}) == nil
    end

    test "is a function, so it is evaluated in the recipient's locale" do
      # A map would already have been evaluated in whatever locale the caller
      # happened to be in — on a background job sending an invoice, nobody's.
      assert is_function(EmailDefaults.defaults_for("billing_invoice"), 0)
      assert is_function(EmailDefaults.defaults_for("billing_invoice", %{}), 0)
    end
  end

  describe "content" do
    test "every template supplies a subject, a Markdown body and a text body" do
      for name <- EmailDefaults.template_names() do
        content = EmailDefaults.defaults_for(name).()

        assert Map.keys(content) |> Enum.sort() == [:markdown, :subject, :text]

        for part <- [:subject, :markdown, :text] do
          assert is_binary(content[part]) and String.trim(content[part]) != "",
                 "empty #{part}: #{name}"
        end
      end
    end

    test "html is absent: the Markdown builds it, inside core's layout" do
      # A module `html` default would outrank nothing a host can't override,
      # but it would duplicate the chrome the shared layout exists to carry.
      for name <- EmailDefaults.template_names() do
        refute Map.has_key?(EmailDefaults.defaults_for(name).(), :html)
      end
    end

    test "the subject and text use exactly the placeholders billing supplies" do
      for {name, expected} <- @text_placeholders do
        content = EmailDefaults.defaults_for(name).()
        actual = placeholders(content.subject <> content.text)

        assert actual == Enum.sort(expected),
               "#{name} placeholders drifted from what build_*_email_variables supplies.\n" <>
                 "added: #{inspect(actual -- Enum.sort(expected))}\n" <>
                 "removed: #{inspect(Enum.sort(expected) -- actual)}"
      end
    end

    test "the Markdown uses exactly the placeholders billing supplies" do
      for {name, expected} <- @markdown_placeholders do
        actual = placeholders(EmailDefaults.defaults_for(name).().markdown)

        assert actual == Enum.sort(expected),
               "#{name} Markdown placeholders drifted.\n" <>
                 "added: #{inspect(actual -- Enum.sort(expected))}\n" <>
                 "removed: #{inspect(Enum.sort(expected) -- actual)}"
      end
    end

    test "the line-items table is raw HTML in the Markdown, never in the text" do
      for name <- ["billing_invoice", "billing_receipt"] do
        content = EmailDefaults.defaults_for(name).()

        assert content.markdown =~ "\n\n{{{line_items_table_html}}}\n\n",
               "#{name}: the table must be a paragraph of its own, in triple braces"

        refute content.text =~ "line_items_table_html"
        refute content.text =~ "line_items_html"
        assert content.text =~ "{{line_items_text}}"
      end
    end

    test "the link to the document online is a button — a paragraph of one link" do
      for {name, variable} <- @link_variables do
        markdown = EmailDefaults.defaults_for(name).().markdown

        assert Regex.match?(~r/\n\n\[[^\]\n]+\]\(\{\{#{variable}\}\}\)\n\n/, markdown),
               "#{name}: no button paragraph for {{#{variable}}}"
      end
    end
  end

  describe "translations" do
    # The plain-text bodies are heredocs, so their msgids end with a newline.
    # The catalogues once carried them without it, so the text version of
    # every billing email reached et and ru readers in English. Every part
    # of every email must come back translated.
    for locale <- ~w(et ru) do
      test "every part of every email is translated into #{locale}" do
        for name <- EmailDefaults.template_names() do
          english = EmailDefaults.for_template(name)

          translated =
            Gettext.with_locale(PhoenixKitBilling.Gettext, unquote(locale), fn ->
              EmailDefaults.for_template(name)
            end)

          for part <- [:subject, :markdown, :text] do
            refute translated[part] == english[part], "#{name} #{part} is not translated"

            assert placeholders(translated[part]) == placeholders(english[part]),
                   "#{name} #{part}: the translation changed the placeholders"
          end

          assert translated.markdown =~ "\n\n{{{line_items_table_html}}}\n\n" or
                   not (english.markdown =~ "line_items_table_html")
        end
      end
    end

    test "the preview's labels and descriptions are translated" do
      english = EmailDefaults.catalog_entries()

      for locale <- ~w(et ru) do
        translated =
          Gettext.with_locale(PhoenixKitBilling.Gettext, locale, &EmailDefaults.catalog_entries/0)

        for {e, t} <- Enum.zip(english, translated) do
          refute t.label == e.label, "#{e.name} label in #{locale}"
          refute t.description == e.description, "#{e.name} description in #{locale}"
        end
      end
    end
  end

  describe "defaults_for/2" do
    # A send with a value for everything gets exactly the full defaults.
    defp full(name), do: EmailDefaults.sample_variables(name)

    test "with a value for everything, it is the full defaults" do
      for name <- EmailDefaults.template_names() do
        assert EmailDefaults.defaults_for(name, full(name)).() ==
                 EmailDefaults.defaults_for(name).()
      end
    end

    test "leaves the button out when the send has no link, a blank one, or not a string" do
      for {name, variable} <- @link_variables, value <- [:absent, nil, "", "  ", 42] do
        variables =
          if value == :absent,
            do: Map.delete(full(name), variable),
            else: Map.put(full(name), variable, value)

        content = EmailDefaults.defaults_for(name, variables).()
        expected = EmailDefaults.defaults_for(name).()

        refute content.markdown =~ "{{#{variable}}}",
               "#{name} kept a button with #{inspect(value)}"

        # Only the button paragraph goes; the rest is the same.
        assert String.replace(expected.markdown, ~r/\n\n\[[^\]]+\]\(\{\{#{variable}\}\}\)/, "") ==
                 content.markdown

        assert content.text == expected.text
      end
    end

    test "leaves the invoice's bank transfer section out when there is no IBAN" do
      variables = Map.put(full("billing_invoice"), "bank_iban", " ")
      markdown = EmailDefaults.defaults_for("billing_invoice", variables).().markdown

      refute markdown =~ "{{bank_iban}}"
      refute markdown =~ "{{bank_name}}"
      refute markdown =~ "Bank transfer"
      assert markdown =~ "{{payment_terms}}"
      # The text version keeps its own layout.
      assert EmailDefaults.defaults_for("billing_invoice", variables).().text =~ "{{bank_iban}}"
    end

    test "leaves each blank line of the company's details out, and the rule with all three" do
      for name <- EmailDefaults.template_names() do
        no_vat = EmailDefaults.defaults_for(name, Map.put(full(name), "company_vat", "")).()
        refute no_vat.markdown =~ "{{company_vat}}"
        assert no_vat.markdown =~ ~r/---\n\n\{\{company_name\}\}\\\n\{\{company_address\}\}\z/

        none =
          Map.merge(full(name), %{"company_name" => "", "company_address" => nil})
          |> Map.delete("company_vat")

        markdown = EmailDefaults.defaults_for(name, none).().markdown
        refute markdown =~ "{{company_address}}"
        refute markdown =~ "{{company_vat}}"
        refute markdown =~ "---"
        refute markdown =~ ~r/\{\{company_name\}\}\z/
      end
    end
  end

  describe "line_items_table_html/2" do
    @items [
      %{
        "name" => "<script>alert(1)</script>",
        "description" => ~s[<img src=x onerror="alert(2)">],
        "quantity" => 2,
        "unit_price" => "15.00",
        "total" => "30.00"
      }
    ]

    test "escapes every value" do
      html = EmailDefaults.line_items_table_html(@items, "EUR")

      refute html =~ "<script"
      refute html =~ "<img"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ "&lt;img src=x onerror=&quot;alert(2)&quot;&gt;"
    end

    test "escapes the currency and a value that is not a name" do
      html =
        EmailDefaults.line_items_table_html(
          [%{"name" => "A", "quantity" => "<b>", "unit_price" => "1", "total" => "<i>"}],
          "<u>"
        )

      refute html =~ ~r/<[biu]>/
      assert html =~ "&lt;b&gt;"
      assert html =~ "&lt;i&gt;&nbsp;&lt;u&gt;"
    end

    test "is one table styled inline — an email has no stylesheet" do
      html = EmailDefaults.line_items_table_html(@items, "EUR")

      assert html =~ ~r/\A<table [^>]*style="[^"]+"/
      assert String.ends_with?(html, "</table>")
      refute html =~ "class="
      assert html =~ "2 × 15.00&nbsp;EUR"
      assert html =~ ~s(text-align:right;white-space:nowrap;">30.00&nbsp;EUR</td>)
    end

    test "reads Decimal values, atom keys, and leaves out a missing description" do
      html =
        EmailDefaults.line_items_table_html([
          %{
            name: "Widget",
            quantity: 3,
            unit_price: Decimal.new("1.50"),
            total: Decimal.new("4.5")
          }
        ])

      assert html =~ "<strong>Widget</strong>"
      assert html =~ "3 × 1.50"
      assert html =~ ">4.5</td>"
      refute html =~ "&nbsp;"
      assert length(Regex.scan(~r/<div /, html)) == 1
    end

    test "no items, no table" do
      assert EmailDefaults.line_items_table_html(nil, "EUR") == ""
      assert EmailDefaults.line_items_table_html([], "EUR") == ""
    end
  end

  describe "line_items_html/1" do
    test "keeps its <tr> rows and classes for a template that wraps them, escaped" do
      html = EmailDefaults.line_items_html(@items)

      assert html =~ ~r/\A<tr>/
      refute html =~ "<table"
      assert html =~ ~s(<div class="item-name">&lt;script&gt;)
      assert html =~ ~s(<div class="item-desc">&lt;img)
      refute html =~ "<script"
      refute html =~ "<img"
      assert html =~ ~s(<td class="text-right" style="text-align:right;">30.00</td>)
    end

    test "no items, no rows" do
      assert EmailDefaults.line_items_html(nil) == ""
      assert EmailDefaults.line_items_html([]) == ""
    end
  end

  describe "line_items_text/1" do
    test "one line per item" do
      assert EmailDefaults.line_items_text([
               %{"name" => "A", "quantity" => 2, "unit_price" => "1.00", "total" => "2.00"},
               %{"name" => "B", "quantity" => 1, "unit_price" => "3.00", "total" => "3.00"}
             ]) == "A x 2 @ 1.00 = 2.00\nB x 1 @ 3.00 = 3.00"

      assert EmailDefaults.line_items_text(nil) == ""
    end
  end

  describe "catalog_entries/0" do
    test "lists the four emails in the billing layout group, with the send's defaults" do
      entries = EmailDefaults.catalog_entries()

      assert Enum.map(entries, & &1.name) == EmailDefaults.template_names()

      for entry <- entries do
        assert is_binary(entry.label) and entry.label != ""
        assert is_binary(entry.description) and entry.description != ""
        assert entry.layout == "billing"
        assert entry.defaults.() == EmailDefaults.defaults_for(entry.name).()
        assert is_function(entry.variables, 0)
      end
    end

    test "the samples bind every placeholder of every part" do
      for entry <- EmailDefaults.catalog_entries() do
        variables = entry.variables.()
        content = entry.defaults.()

        for part <- [:subject, :markdown, :text] do
          assert Substitution.missing(content[part], variables) == [],
                 "#{entry.name} #{part}: samples leave " <>
                   inspect(Substitution.missing(content[part], variables))
        end

        assert variables[Map.fetch!(@link_variables, entry.name)] =~
                 ~r/\Ahttps:\/\/example\.com\//
      end
    end

    test "the samples' line items are built by the functions a send uses" do
      variables = EmailDefaults.sample_variables("billing_invoice")

      assert variables["line_items_table_html"] =~ ~r/\A<table /
      assert variables["line_items_html"] =~ ~r/\A<tr>/
      assert variables["line_items_text"] =~ " x "
    end

    test "is what the module registers with core's preview" do
      assert Enum.map(PhoenixKitBilling.email_templates(), & &1.name) ==
               EmailDefaults.template_names()

      assert Enum.map(LegacyBilling.email_templates(), & &1.name) ==
               EmailDefaults.template_names()
    end
  end

  describe "PhoenixKitBilling.email_send_opts/4" do
    test "carries the defaults, the billing layout group and the customer's locale" do
      user = %{uuid: "u-1", custom_fields: %{"preferred_locale" => "et"}}
      variables = EmailDefaults.sample_variables("billing_invoice")

      opts = PhoenixKitBilling.email_send_opts("billing_invoice", variables, user, %{a: 1})

      assert opts[:locale] == "et"
      assert opts[:layout] == "billing"
      assert opts[:user_uuid] == "u-1"
      assert opts[:metadata] == %{a: 1}
      assert opts[:defaults].() == EmailDefaults.defaults_for("billing_invoice").()
    end

    test "a guest payer or a user without a preference sends no locale" do
      # `nil` lets core fall back to the site's language.
      assert PhoenixKitBilling.email_send_opts("billing_receipt", %{}, nil, %{})[:locale] == nil

      assert PhoenixKitBilling.email_send_opts(
               "billing_receipt",
               %{},
               %{uuid: "u", custom_fields: %{}},
               %{}
             )[
               :locale
             ] == nil
    end

    test "the defaults drop the button when the send has no link" do
      opts =
        PhoenixKitBilling.email_send_opts("billing_receipt", %{"receipt_url" => ""}, nil, %{})

      refute opts[:defaults].().markdown =~ "{{receipt_url}}"
    end
  end
end
