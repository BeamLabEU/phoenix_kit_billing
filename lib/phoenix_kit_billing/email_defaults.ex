defmodule PhoenixKitBilling.EmailDefaults do
  @moduledoc """
  The content billing's four financial emails fall back to, the line-items
  fragments they carry, and their entries in core's email preview.

  Handed to `PhoenixKit.Mailer.send_from_template/4` as `:defaults`, which
  resolves in order: an active database template, then a host override file for
  the recipient's locale, then this. **A host that customized one of these
  templates keeps its customization** — the database still wins — so adopting
  this changes nothing for an existing install.

  ## The parts

  Each email has a `subject`, a `markdown` body and a `text` body.

    * `markdown` builds the HTML version. Core renders it inside its shared
      layout (`PhoenixKit.Email.Layout`) in the `"billing"` group, so a host
      can give billing emails their own chrome with `_layout-billing`,
      `_header-billing` or `_footer-billing`. The link to the document online
      is a button; the company's details close the body, so they reach the
      customer whatever header and footer the host has.
    * `text` builds the plain-text version. It is a separate part rather than
      the Markdown converted, because the HTML version carries the line items
      as a ready-made table (`{{{line_items_table_html}}}`), which has no
      place in plain text; the text version uses `{{line_items_text}}`.

  A host that overrides only `text.txt` changes the plain-text version; from
  the core release that ranks a host's text above a module's Markdown in the
  HTML body, the HTML version is then built from that text too, without the
  line-items table. To keep the table, place `{{{line_items_table_html}}}` in
  a host `html.html` — billing's `text` default still builds the plain-text
  version — or in a host `markdown.md` **together with** a host `text.txt`
  using `{{line_items_text}}`: a host's Markdown outranks billing's `text`
  default for the plain-text version too, and would carry the table's HTML
  into it.

  ## Line items

  `line_items_table_html/2` is the whole table, escaped and styled inline (an
  email has no stylesheet). `line_items_html/1` is the older form — bare
  `<tr>` rows for a template that wraps them in its own `<table>`, which every
  database template and every `html.html` exported from one does; it keeps
  that shape and is escaped too. `line_items_text/1` is one line per item.

  ## Why these are functions, not a map

  Billing's send options wrap the zero-arity `:defaults` in the recipient's
  locale for this module's backend, and core's preview installs its chosen
  locale too. A map would have been evaluated in whatever locale the
  caller happened to be in — which, on a background job sending an invoice, is
  nobody's.
  """

  use Gettext, backend: PhoenixKitBilling.Gettext

  @templates ~w(billing_invoice billing_receipt billing_credit_note billing_payment_confirmation)

  # The layout group every billing email is wrapped in.
  @layout_group "billing"

  # The variable holding each email's link to the document online. When a
  # send has none, the button is left out rather than shown as a bare label.
  @link_variables %{
    "billing_invoice" => "invoice_url",
    "billing_receipt" => "receipt_url",
    "billing_credit_note" => "credit_note_url",
    "billing_payment_confirmation" => "payment_url"
  }

  @font "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

  # Secondary text in a line item: the description, quantity × unit price.
  @muted "color:#71717a;font-size:13px;"

  @cell_style "padding:10px 0;border-bottom:1px solid #e4e4e7;vertical-align:top;" <>
                "font-family:#{@font};font-size:14px;line-height:1.4;color:#18181b;"

  @doc "The template names this module supplies defaults for."
  @spec template_names() :: [String.t()]
  def template_names, do: @templates

  @doc """
  The layout group billing emails are sent in — passed to the send as
  `layout: "billing"`.
  """
  @spec layout_group() :: String.t()
  def layout_group, do: @layout_group

  @doc """
  A zero-arity function returning the default content for `name`, or `nil` when
  this module has nothing to say about that name.
  """
  @spec defaults_for(String.t()) ::
          (-> %{subject: String.t(), markdown: String.t(), text: String.t()}) | nil
  def defaults_for(name) when name in @templates, do: fn -> for_template(name) end
  def defaults_for(_name), do: nil

  @doc """
  `defaults_for/1` for one send. Both bodies leave out what `variables` have
  nothing for, rather than show an empty label: the button when there is no
  link to the document online, the invoice's bank transfer section when there
  is no IBAN, and each line of the company's details that is blank.
  """
  @spec defaults_for(String.t(), map()) ::
          (-> %{subject: String.t(), markdown: String.t(), text: String.t()}) | nil
  def defaults_for(name, variables) when name in @templates and is_map(variables) do
    present =
      for {key, value} <- variables,
          is_binary(value) and String.trim(value) != "",
          into: MapSet.new(),
          do: to_string(key)

    fn -> for_template(name, present) end
  end

  def defaults_for(_name, _variables), do: nil

  @doc """
  The default content for `name`, evaluated in the current locale.

  `present` is `:all`, or the names of the variables a send has a value for —
  see `defaults_for/2`.
  """
  @spec for_template(String.t(), :all | MapSet.t(String.t())) :: %{
          subject: String.t(),
          markdown: String.t(),
          text: String.t()
        }
  def for_template(name, present \\ :all) when name in @templates do
    %{subject: subject(name), markdown: markdown(name, present), text: text(name, present)}
  end

  defp has?(:all, _variable), do: true
  defp has?(present, variable), do: MapSet.member?(present, variable)

  # The button to the document online, when the send has a link for it.
  defp button(name, present, label) do
    if has?(present, Map.fetch!(@link_variables, name)), do: label
  end

  ## Line items

  @doc """
  The line items as one HTML table, for `{{{line_items_table_html}}}`.

  Every value is HTML-escaped; styles are inline. An item reads as its name,
  its description, `quantity × unit price` and, on the right, its total —
  amounts followed by `currency` when one is given. No items, no table (`""`).
  """
  @spec line_items_table_html([map()] | nil, String.t() | nil) :: String.t()
  def line_items_table_html(items, currency \\ nil)
  def line_items_table_html(nil, _currency), do: ""
  def line_items_table_html([], _currency), do: ""

  def line_items_table_html(items, currency) when is_list(items) do
    rows = Enum.map_join(items, "", &table_row(&1, currency))

    ~s(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" ) <>
      ~s(style="width:100%;border-collapse:collapse;margin:0 0 16px;">) <>
      rows <> "</table>"
  end

  defp table_row(item, currency) do
    description =
      case cell(field(item, "description")) do
        "" -> ""
        text -> ~s(<div style="#{@muted}">#{text}</div>)
      end

    quantity =
      ~s(<div style="#{@muted}">) <>
        cell(field(item, "quantity")) <>
        " × " <> amount(field(item, "unit_price"), currency) <> "</div>"

    "<tr>" <>
      ~s(<td style="#{@cell_style}">) <>
      ~s(<strong>#{cell(field(item, "name"))}</strong>) <>
      description <>
      quantity <>
      "</td>" <>
      ~s(<td align="right" style="#{@cell_style}padding-left:16px;text-align:right;white-space:nowrap;">) <>
      amount(field(item, "total"), currency) <>
      "</td></tr>"
  end

  @doc """
  The line items as bare `<tr>` rows, for a template that places
  `{{{line_items_html}}}` inside its own `<table>` — every database template
  and every `html.html` exported from one. Values are HTML-escaped.
  """
  @spec line_items_html([map()] | nil) :: String.t()
  def line_items_html(nil), do: ""

  def line_items_html(items) when is_list(items) do
    Enum.map_join(items, "\n", fn item ->
      desc =
        case cell(field(item, "description")) do
          "" -> ""
          text -> ~s(<div class="item-desc" style="#{@muted}">#{text}</div>)
        end

      """
      <tr>
        <td>
          <div class="item-name" style="font-weight:bold;">#{cell(field(item, "name"))}</div>
          #{desc}
        </td>
        <td class="text-right" style="text-align:right;">#{cell(field(item, "quantity"))}</td>
        <td class="text-right" style="text-align:right;">#{cell(field(item, "unit_price"))}</td>
        <td class="text-right" style="text-align:right;">#{cell(field(item, "total"))}</td>
      </tr>
      """
    end)
  end

  @doc "The line items as plain text, one per line, for `{{line_items_text}}`."
  @spec line_items_text([map()] | nil) :: String.t()
  def line_items_text(nil), do: ""

  def line_items_text(items) when is_list(items) do
    Enum.map_join(items, "\n", fn item ->
      "#{plain(field(item, "name"))} x #{plain(field(item, "quantity"))} @ #{plain(field(item, "unit_price"))} = " <>
        plain(field(item, "total"))
    end)
  end

  # A value as escaped HTML. Line items are JSON, so a value is a string, a
  # number, or — from a struct built in code — a Decimal; anything else is
  # not a value to print.
  defp cell(value),
    do: value |> plain() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp amount(value, currency) do
    case {cell(value), cell(currency)} do
      {"", _currency} -> ""
      {value, ""} -> value
      {value, currency} -> value <> "&nbsp;" <> currency
    end
  end

  # Stored line items have string keys; an invoice struct fresh from
  # `create_invoice/2` still carries the keys it was built with.
  @item_keys %{
    "name" => :name,
    "description" => :description,
    "quantity" => :quantity,
    "unit_price" => :unit_price,
    "total" => :total
  }

  defp field(item, key) when is_map(item),
    do: Map.get(item, key, Map.get(item, Map.fetch!(@item_keys, key)))

  defp field(_item, _key), do: nil

  defp plain(nil), do: ""
  defp plain(value) when is_binary(value), do: value
  defp plain(value) when is_number(value), do: to_string(value)
  defp plain(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp plain(_value), do: ""

  ## The preview

  @doc false
  @spec format_date(Date.t() | DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def format_date(nil), do: ""

  def format_date(%{day: day, month: month, year: year}) do
    day = day |> to_string() |> String.pad_leading(2, "0")
    month = PhoenixKit.Utils.Date.short_month(month)

    case Gettext.get_locale(PhoenixKitWeb.Gettext) do
      "en" -> "#{month} #{day}, #{year}"
      _ -> "#{day} #{month} #{year}"
    end
  end

  @doc """
  The four emails as `PhoenixKit.Email.Catalog` entries, for core's email
  preview — returned by `PhoenixKitBilling.email_templates/0`.

  `defaults` is the function a send passes when it has a link to the document,
  and the sample variables are built by the same line-items functions a send
  uses, so the preview shows what a customer gets.
  """
  @spec catalog_entries() :: [map()]
  def catalog_entries do
    [
      entry(
        "billing_invoice",
        gettext("Invoice"),
        gettext(
          "Sent to the customer when an invoice is sent: line items, totals, bank transfer details and a link to the invoice."
        )
      ),
      entry(
        "billing_receipt",
        gettext("Receipt"),
        gettext("Sent to the customer with the receipt for a paid invoice.")
      ),
      entry(
        "billing_credit_note",
        gettext("Credit note"),
        gettext("Sent to the customer when a refund is issued: the amount and the reason.")
      ),
      entry(
        "billing_payment_confirmation",
        gettext("Payment confirmation"),
        gettext(
          "Sent to the customer for a payment against an invoice, with the remaining balance."
        )
      )
    ]
  end

  defp entry(name, label, description) do
    %{
      name: name,
      label: label,
      description: description,
      defaults: fn ->
        Gettext.with_locale(
          PhoenixKitBilling.Gettext,
          Gettext.get_locale(PhoenixKitWeb.Gettext),
          defaults_for(name)
        )
      end,
      variables: fn -> sample_variables(name) end,
      layout: @layout_group
    }
  end

  @sample_items [
    %{
      "name" => "Website hosting, 12 months",
      "description" => "Business plan, billed yearly",
      "quantity" => 1,
      "unit_price" => "240.00",
      "total" => "240.00"
    },
    %{
      "name" => "Domain renewal",
      "description" => "example.com",
      "quantity" => 2,
      "unit_price" => "15.00",
      "total" => "30.00"
    }
  ]

  @sample_company %{
    "company_name" => "Acme Ltd",
    "company_address" => "1 Example Street, 10001 Example City",
    "company_vat" => "XX123456789",
    "document_footer" => "Acme — tools for every home. Prices include VAT.",
    "user_name" => "Jane Doe",
    "user_email" => "jane.doe@example.com",
    "currency" => "EUR"
  }

  @doc """
  Sample variables for `name`: every placeholder its defaults use, with
  synthetic values.
  """
  @spec sample_variables(String.t()) :: map()
  def sample_variables("billing_invoice") do
    Map.merge(@sample_company, %{
      "invoice_number" => "INV-2026-0042",
      "invoice_date" => format_date(~D[2026-10-02]),
      "due_date" => format_date(~D[2026-10-16]),
      "subtotal" => "270.00",
      "tax_amount" => "59.40",
      "total" => "329.40",
      "line_items_html" => line_items_html(@sample_items),
      "line_items_table_html" => line_items_table_html(@sample_items, "EUR"),
      "line_items_text" => line_items_text(@sample_items),
      "bank_name" => "Example Bank",
      "bank_iban" => "DE89 3704 0044 0532 0130 00",
      "bank_swift" => "EXAMDEFFXXX",
      "payment_terms" => "Payment due within 14 days.",
      "invoice_url" => "https://example.com/invoices/INV-2026-0042"
    })
  end

  def sample_variables("billing_receipt") do
    Map.merge(@sample_company, %{
      "receipt_number" => "RCP-2026-0042",
      "invoice_number" => "INV-2026-0042",
      "payment_date" => format_date(~D[2026-10-05]),
      "subtotal" => "270.00",
      "tax_amount" => "59.40",
      "total" => "329.40",
      "paid_amount" => "329.40",
      "line_items_html" => line_items_html(@sample_items),
      "line_items_table_html" => line_items_table_html(@sample_items, "EUR"),
      "line_items_text" => line_items_text(@sample_items),
      "receipt_url" => "https://example.com/receipts/RCP-2026-0042"
    })
  end

  def sample_variables("billing_credit_note") do
    Map.merge(@sample_company, %{
      "credit_note_number" => "CN-2026-0007",
      "invoice_number" => "INV-2026-0042",
      "refund_date" => format_date(~D[2026-10-09]),
      "refund_amount" => "30.00",
      "refund_reason" => "Domain renewal cancelled",
      "transaction_number" => "TXN-2026-0107",
      "credit_note_url" => "https://example.com/credit-notes/CN-2026-0007"
    })
  end

  def sample_variables("billing_payment_confirmation") do
    Map.merge(@sample_company, %{
      "confirmation_number" => "PMT-2026-0106",
      "invoice_number" => "INV-2026-0042",
      "payment_date" => format_date(~D[2026-10-05]),
      "payment_amount" => "200.00",
      "payment_method" => "Bank",
      "transaction_number" => "TXN-2026-0106",
      "invoice_total" => "329.40",
      "total_paid" => "200.00",
      "remaining_balance" => "129.40",
      "payment_url" => "https://example.com/payments/PMT-2026-0106"
    })
  end

  ## Subjects

  defp subject("billing_invoice"), do: gettext("Invoice {{invoice_number}} - {{company_name}}")
  defp subject("billing_receipt"), do: gettext("Receipt {{receipt_number}} - {{company_name}}")

  defp subject("billing_credit_note"),
    do: gettext("Credit Note {{credit_note_number}} - Refund Issued - {{company_name}}")

  defp subject("billing_payment_confirmation"),
    do: gettext("Payment Received - {{confirmation_number}} - {{company_name}}")

  ## Markdown bodies
  #
  # Each body is a few short msgids rather than one: a translator sees a
  # paragraph at a time, and the button can be left out on its own. The
  # line-items table is placed by code, never by a translation.

  defp markdown("billing_invoice", present) do
    join([
      gettext("""
      ## Invoice {{invoice_number}}

      Hello {{user_name}},

      Here is your invoice from {{company_name}}.
      """),
      has?(present, "due_date") && gettext("Please pay it by {{due_date}}."),
      has?(present, "line_items_table_html") && "{{{line_items_table_html}}}",
      gettext("""
      - Subtotal: {{subtotal}} {{currency}}
      - Tax: {{tax_amount}} {{currency}}
      - **Total due: {{total}} {{currency}}**
      """),
      button("billing_invoice", present, gettext("[View invoice]({{invoice_url}})")),
      bank_transfer(present, :markdown),
      gettext("""
      Invoice date: {{invoice_date}}. {{payment_terms}}

      If you have any questions about this invoice, please contact us.
      """),
      company_footer(present)
    ])
  end

  defp markdown("billing_receipt", present) do
    join([
      gettext("""
      ## Receipt {{receipt_number}}

      Hello {{user_name}},

      Thank you for your payment. We received {{paid_amount}} {{currency}} for invoice {{invoice_number}} on {{payment_date}}.
      """),
      has?(present, "line_items_table_html") && "{{{line_items_table_html}}}",
      gettext("""
      - Subtotal: {{subtotal}} {{currency}}
      - Tax: {{tax_amount}} {{currency}}
      - **Total paid: {{paid_amount}} {{currency}}**
      """),
      button("billing_receipt", present, gettext("[View receipt]({{receipt_url}})")),
      gettext("Thank you for your business. If you have any questions, please contact us."),
      company_footer(present)
    ])
  end

  defp markdown("billing_credit_note", present) do
    join([
      gettext("""
      ## Credit note {{credit_note_number}}

      Hello {{user_name}},

      We have issued a refund of **{{refund_amount}} {{currency}}** for invoice {{invoice_number}}.

      - Credit note: {{credit_note_number}}
      - Refund date: {{refund_date}}
      - Original invoice: {{invoice_number}}
      - Transaction: {{transaction_number}}
      - Reason: {{refund_reason}}
      """),
      button("billing_credit_note", present, gettext("[View credit note]({{credit_note_url}})")),
      gettext("""
      The refund goes back to your original payment method. Please allow 5–10 business days for it to appear in your account.

      If you have any questions about this refund, please contact us.
      """),
      company_footer(present)
    ])
  end

  defp markdown("billing_payment_confirmation", present) do
    join([
      gettext("""
      ## Payment received

      Hello {{user_name}},

      Thank you for your payment of **{{payment_amount}} {{currency}}** for invoice {{invoice_number}}.

      - Confirmation: {{confirmation_number}}
      - Payment date: {{payment_date}}
      - Payment method: {{payment_method}}
      - Transaction: {{transaction_number}}

      **Balance**

      - Invoice total: {{invoice_total}} {{currency}}
      - Total paid: {{total_paid}} {{currency}}
      - **Remaining balance: {{remaining_balance}} {{currency}}**
      """),
      button(
        "billing_payment_confirmation",
        present,
        gettext("[View payment confirmation]({{payment_url}})")
      ),
      gettext("Thank you for your business. If you have any questions, please contact us."),
      company_footer(present)
    ])
  end

  # The seller's details, closing every body: whatever header and footer the
  # host's layout carries, an invoice states who issued it. Lines are joined
  # with a trailing `\`, a Markdown line break; a blank one is left out. The
  # text about the company set for billing documents follows as a paragraph.
  defp company_footer(present) do
    case join([company_lines(present, "\\\n"), document_footer(present)]) do
      "" -> nil
      footer -> "---\n\n" <> footer
    end
  end

  defp document_footer(present) do
    if has?(present, "document_footer"), do: "{{document_footer}}"
  end

  defp company_lines(present, separator) do
    [
      has?(present, "company_name") && "{{company_name}}",
      has?(present, "company_address") && "{{company_address}}",
      has?(present, "company_vat") && gettext("VAT: {{company_vat}}")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(separator)
  end

  defp bank_transfer(present, format) do
    if has?(present, "bank_iban") do
      heading =
        case format do
          :markdown -> gettext("### Bank transfer")
          :text -> gettext("BANK TRANSFER DETAILS")
        end

      lines =
        [
          has?(present, "bank_name") && gettext("Bank: {{bank_name}}"),
          gettext("IBAN: {{bank_iban}}"),
          has?(present, "bank_swift") && gettext("SWIFT/BIC: {{bank_swift}}"),
          gettext("Reference: {{invoice_number}}")
        ]
        |> Enum.filter(&is_binary/1)

      case format do
        :markdown -> heading <> "\n\n" <> Enum.map_join(lines, "\n", &("- " <> &1))
        :text -> heading <> "\n" <> Enum.join(lines, "\n")
      end
    end
  end

  defp join(parts) do
    parts
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map_join("\n\n", &String.trim/1)
  end

  ## Text bodies

  defp text("billing_invoice", present) do
    join([
      gettext("""
      =============================================
      INVOICE {{invoice_number}}
      =============================================
      """),
      gettext("""
      Bill To: {{user_name}}
      Email: {{user_email}}
      """),
      join_lines([
        gettext("Invoice Date: {{invoice_date}}"),
        has?(present, "due_date") && gettext("Due Date: {{due_date}}"),
        gettext("Currency: {{currency}}")
      ]),
      has?(present, "line_items_text") &&
        gettext("""
        ---------------------------------------------
        LINE ITEMS
        ---------------------------------------------
        {{line_items_text}}
        """),
      gettext("""
      ---------------------------------------------
      SUMMARY
      ---------------------------------------------
      Subtotal:    {{subtotal}} {{currency}}
      Tax:         {{tax_amount}} {{currency}}
      ---------------------------------------------
      TOTAL:       {{total}} {{currency}}
      ---------------------------------------------
      """),
      join_lines([
        has?(present, "due_date") && gettext("PAYMENT DUE: {{due_date}}"),
        has?(present, "payment_terms") && "{{payment_terms}}"
      ]),
      bank_transfer(present, :text),
      has?(present, "invoice_url") &&
        gettext("""
        ---------------------------------------------
        View invoice online: {{invoice_url}}
        """),
      text_company_footer(present),
      gettext("If you have any questions about this invoice, please contact us.")
    ])
  end

  defp text("billing_receipt", present) do
    join([
      gettext("""
      =============================================
      RECEIPT {{receipt_number}}
      =============================================
      STATUS: PAID
      """),
      gettext("""
      Thank you for your payment!
      Your payment has been successfully processed.
      """),
      gettext("""
      ---------------------------------------------
      RECEIVED FROM
      ---------------------------------------------
      Name: {{user_name}}
      Email: {{user_email}}
      """),
      gettext("""
      Payment Date: {{payment_date}}
      Invoice: {{invoice_number}}
      Currency: {{currency}}
      """),
      has?(present, "line_items_text") &&
        gettext("""
        ---------------------------------------------
        LINE ITEMS
        ---------------------------------------------
        {{line_items_text}}
        """),
      gettext("""
      ---------------------------------------------
      SUMMARY
      ---------------------------------------------
      Subtotal:    {{subtotal}} {{currency}}
      Tax:         {{tax_amount}} {{currency}}
      ---------------------------------------------
      TOTAL PAID:  {{paid_amount}} {{currency}}
      ---------------------------------------------
      """),
      gettext("PAYMENT CONFIRMED: {{payment_date}}"),
      has?(present, "receipt_url") &&
        gettext("""
        ---------------------------------------------
        View receipt online: {{receipt_url}}
        """),
      text_company_footer(present),
      gettext("""
      Thank you for your business.
      If you have any questions, please contact us.
      """)
    ])
  end

  defp text("billing_credit_note", present) do
    join([
      gettext("""
      =============================================
      CREDIT NOTE {{credit_note_number}}
      =============================================
      STATUS: REFUND ISSUED
      """),
      gettext("A refund has been processed for your account."),
      gettext("REFUND AMOUNT: {{refund_amount}} {{currency}}"),
      text_company_issuer(present),
      gettext("""
      ---------------------------------------------
      ISSUED TO (PAYEE)
      ---------------------------------------------
      Name: {{user_name}}
      Email: {{user_email}}
      """),
      gettext("""
      ---------------------------------------------
      REFUND DETAILS
      ---------------------------------------------
      Credit Note #:     {{credit_note_number}}
      Refund Date:       {{refund_date}}
      Refund Amount:     {{refund_amount}} {{currency}}
      Original Invoice:  {{invoice_number}}
      Transaction #:     {{transaction_number}}
      """),
      gettext("""
      ---------------------------------------------
      REASON FOR REFUND
      ---------------------------------------------
      {{refund_reason}}
      """),
      has?(present, "credit_note_url") &&
        gettext("""
        ---------------------------------------------
        View credit note online: {{credit_note_url}}
        """),
      gettext("""
      The refund will be processed to your original payment method.
      Please allow 5-10 business days for the refund to appear in your account.
      """),
      text_company_footer(present),
      gettext("If you have any questions about this refund, please contact us.")
    ])
  end

  defp text("billing_payment_confirmation", present) do
    join([
      gettext("""
      =============================================
      PAYMENT CONFIRMATION {{confirmation_number}}
      =============================================
      STATUS: PAYMENT RECEIVED
      """),
      gettext("Thank you for your payment."),
      gettext("PAYMENT AMOUNT: {{payment_amount}} {{currency}}"),
      gettext("""
      ---------------------------------------------
      PAYMENT DETAILS
      ---------------------------------------------
      Confirmation #:    {{confirmation_number}}
      Invoice #:         {{invoice_number}}
      Payment Date:      {{payment_date}}
      Payment Method:    {{payment_method}}
      Transaction #:     {{transaction_number}}
      """),
      gettext("""
      ---------------------------------------------
      BALANCE SUMMARY
      ---------------------------------------------
      Invoice Total:     {{invoice_total}} {{currency}}
      Total Paid:        {{total_paid}} {{currency}}
      Remaining:         {{remaining_balance}} {{currency}}
      """),
      has?(present, "payment_url") &&
        gettext("""
        ---------------------------------------------
        View payment confirmation online: {{payment_url}}
        """),
      text_company_footer(present),
      gettext("Thank you for your business. If you have any questions, please contact us.")
    ])
  end

  defp text_company_footer(present) do
    case join([company_lines(present, "\n"), document_footer(present)]) do
      "" ->
        nil

      footer ->
        "=============================================\n" <>
          footer <> "\n============================================="
    end
  end

  defp text_company_issuer(present) do
    case company_lines(present, "\n") do
      "" ->
        nil

      lines ->
        join([
          gettext("""
          ---------------------------------------------
          ISSUED BY (PAYER)
          ---------------------------------------------
          """),
          lines
        ])
    end
  end

  defp join_lines(parts), do: parts |> Enum.filter(&is_binary/1) |> Enum.join("\n")
end
