defmodule PhoenixKitBilling.Integration.EmailRenderingTest do
  @moduledoc """
  Billing's four financial emails, rendered by core exactly as a send renders
  them: `PhoenixKit.Email.Content.resolve/5` with the options
  `PhoenixKitBilling.email_send_opts/4` hands to
  `PhoenixKit.Mailer.send_from_template/4`, and core's preview
  (`PhoenixKit.Email.Catalog.preview/3`) over `email_templates/0`.

  The send itself goes through `phoenix_kit_emails`, which this suite does not
  install (see `regression/send_email_module_check_test.exs`), so the
  rendering is checked one step before delivery, with the same inputs.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKit.Email.Catalog
  alias PhoenixKit.Email.Content
  alias PhoenixKit.Templates.Substitution
  alias PhoenixKit.Users.Auth
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.EmailDefaults

  # An empty override root: no host file, so every part is billing's default.
  setup do
    root = Path.join(System.tmp_dir!(), "billing-email-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{paths: [root]}
  end

  defp user_fixture(custom_fields \\ %{}) do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "billing-email-#{System.unique_integer([:positive])}@example.com",
        "password" => "password1234567"
      })

    %{user | custom_fields: Map.merge(user.custom_fields || %{}, custom_fields)}
  end

  defp invoice_fixture(user, line_items) do
    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{
        subtotal: Decimal.new("30.00"),
        tax_amount: Decimal.new("0"),
        total: Decimal.new("30.00"),
        currency: "EUR",
        line_items: line_items
      })

    %{invoice | user: user}
  end

  # What the send renders, through core, with the send's own options.
  defp render(template, variables, user, paths) do
    opts = Billing.email_send_opts(template, variables, user, %{})

    Content.resolve(template, user.email, variables, opts[:defaults],
      locale: opts[:locale],
      layout: opts[:layout],
      paths: paths
    )
  end

  # The anchor of the button core builds from a paragraph of one link.
  @button ~r/<a href="https:[^"]*" style="display:inline-block;/

  @hostile_items [
    %{
      "name" => "<script>alert(1)</script>",
      "description" => ~s[<img src=x onerror="alert(2)">],
      "quantity" => 2,
      "unit_price" => "15.00",
      "total" => "30.00"
    }
  ]

  describe "the invoice email" do
    test "carries the line-items table, escaped, and the button", %{paths: paths} do
      user = user_fixture()
      invoice = invoice_fixture(user, @hostile_items)

      variables =
        Billing.build_invoice_email_variables(invoice, user,
          invoice_url: "https://example.com/invoices/1"
        )

      content = render("billing_invoice", variables, user, paths)

      refute content.html =~ "<script"
      refute content.html =~ "<img src=x"
      assert content.html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert content.html =~ "2 × 15.00&nbsp;EUR"
      assert content.html =~ ~s(href="https://example.com/invoices/1")
      assert content.html =~ @button

      # The text version lists the items as text — no HTML of the table.
      assert content.text =~ "<script>alert(1)</script> x 2 @ 15.00 = 30.00"
      refute content.text =~ "<table"
      refute content.text =~ "&lt;"
    end

    test "has no button when the send has no link", %{paths: paths} do
      user = user_fixture()
      invoice = invoice_fixture(user, @hostile_items)
      variables = Billing.build_invoice_email_variables(invoice, user, [])

      content = render("billing_invoice", variables, user, paths)

      refute content.html =~ @button
      refute content.html =~ "View invoice"
      assert content.html =~ "&lt;script&gt;"
    end

    test "an invoice without items has no table and no empty paragraph", %{paths: paths} do
      user = user_fixture()
      invoice = invoice_fixture(user, [])
      variables = Billing.build_invoice_email_variables(invoice, user, [])

      html = render("billing_invoice", variables, user, paths).html

      refute html =~ ~r/<p[^>]*>\s*<\/p>/

      refute html =~
               ~s(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse)

      assert html =~ "Subtotal"
    end

    test "every placeholder is filled by what billing supplies", %{paths: paths} do
      user = user_fixture()
      invoice = invoice_fixture(user, @hostile_items)

      variables =
        Billing.build_invoice_email_variables(invoice, user, invoice_url: "https://example.com/i")

      defaults = EmailDefaults.defaults_for("billing_invoice").()

      for part <- [:subject, :markdown, :text] do
        assert Substitution.missing(defaults[part], variables) == [], "#{part} left unbound"
      end

      content = render("billing_invoice", variables, user, paths)
      refute content.html =~ "{{"
      refute content.text =~ "{{"
    end
  end

  describe "the other three emails" do
    test "every placeholder is filled by what billing supplies", %{paths: paths} do
      user = user_fixture()
      invoice = invoice_fixture(user, @hostile_items)

      transaction = %PhoenixKitBilling.Transaction{
        transaction_number: "TXN-2026-0001",
        amount: Decimal.new("30.00"),
        currency: "EUR",
        payment_method: "bank",
        description: "Partial refund",
        inserted_at: DateTime.utc_now()
      }

      invoice = %{invoice | receipt_number: "RCP-1", paid_amount: Decimal.new("30.00")}

      cases = [
        {"billing_receipt",
         Billing.build_receipt_email_variables(invoice, user,
           receipt_url: "https://example.com/r"
         )},
        {"billing_credit_note",
         Billing.build_credit_note_email_variables(invoice, transaction, user,
           credit_note_url: "https://example.com/c"
         )},
        {"billing_payment_confirmation",
         Billing.build_payment_confirmation_email_variables(invoice, transaction, user,
           payment_url: "https://example.com/p"
         )}
      ]

      for {template, variables} <- cases do
        defaults = EmailDefaults.defaults_for(template).()

        for part <- [:subject, :markdown, :text] do
          assert Substitution.missing(defaults[part], variables) == [],
                 "#{template} #{part} left #{inspect(Substitution.missing(defaults[part], variables))}"
        end

        content = render(template, variables, user, paths)
        refute content.html =~ "{{", "#{template} html"
        refute content.text =~ "{{", "#{template} text"
        assert content.html =~ @button, "#{template} has no button"
      end
    end
  end

  describe "core's preview" do
    test "lists the four emails and renders each from its samples", %{paths: paths} do
      for entry <- Billing.email_templates() do
        assert {:ok, preview} = Catalog.preview(entry, "en", paths: paths)

        assert preview.missing |> Map.values() |> List.flatten() == [],
               "#{entry.name}: samples leave #{inspect(preview.missing)}"

        assert preview.sources.group == "billing"
        assert preview.sources.group_from == :option
        assert preview.sources.html_from == :markdown
        assert preview.sources.text_from == :text
        assert preview.content.html =~ @button, "#{entry.name} has no button"
      end
    end

    test "shows the line-items table", %{paths: paths} do
      entry = Enum.find(Billing.email_templates(), &(&1.name == "billing_invoice"))
      {:ok, preview} = Catalog.preview(entry, "en", paths: paths)

      assert preview.content.html =~ "<strong>Website hosting, 12 months</strong>"
      assert preview.content.text =~ "Website hosting, 12 months x 1 @ 240.00 = 240.00"
    end
  end

  describe "the billing layout group" do
    test "a host's _footer-billing wraps billing emails", %{paths: [root] = paths} do
      File.mkdir_p!(Path.join(root, "_footer-billing"))
      File.write!(Path.join([root, "_footer-billing", "html.html"]), "<p>Billing footer</p>")

      user = user_fixture()
      invoice = invoice_fixture(user, @hostile_items)
      variables = Billing.build_invoice_email_variables(invoice, user, [])

      assert render("billing_invoice", variables, user, paths).html =~ "Billing footer"
    end
  end

  describe "the customer's language" do
    test "all email dates follow the recipient and restore the sender's locale" do
      date = ~U[2026-10-16 12:00:00Z]

      for {locale, expected} <- [
            {"en-GB", "Oct 16, 2026"},
            {"et", "16 Okt 2026"},
            {"ru-RU", "16 Окт 2026"}
          ] do
        user = user_fixture(%{"preferred_locale" => locale})
        invoice = invoice_fixture(user, [])
        invoice = %{invoice | inserted_at: date, due_date: DateTime.to_date(date), paid_at: date}

        transaction = %PhoenixKitBilling.Transaction{
          transaction_number: "TXN-2026-1",
          amount: Decimal.new("30.00"),
          currency: "EUR",
          inserted_at: DateTime.to_naive(date)
        }

        Gettext.with_locale(PhoenixKitWeb.Gettext, "ru", fn ->
          cases = [
            {Billing.build_invoice_email_variables(invoice, user, []), ~w(invoice_date due_date)},
            {Billing.build_receipt_email_variables(invoice, user, []), ~w(payment_date)},
            {Billing.build_credit_note_email_variables(invoice, transaction, user, []),
             ~w(refund_date)},
            {Billing.build_payment_confirmation_email_variables(invoice, transaction, user, []),
             ~w(payment_date)}
          ]

          for {variables, keys} <- cases, key <- keys do
            assert variables[key] == expected, "#{locale} #{key}"
          end

          assert Gettext.get_locale(PhoenixKitWeb.Gettext) == "ru"
        end)
      end
    end

    test "an explicit sender locale does not override the recipient", %{paths: paths} do
      user = user_fixture(%{"preferred_locale" => "et"})
      invoice = invoice_fixture(user, [])

      Gettext.with_locale(PhoenixKitBilling.Gettext, "ru", fn ->
        variables = Billing.build_invoice_email_variables(invoice, user, [])
        content = render("billing_invoice", variables, user, paths)

        assert String.starts_with?(content.subject, "Arve ")
        assert content.html =~ "Tasumisele kuulub"
        assert Gettext.get_locale(PhoenixKitBilling.Gettext) == "ru"
      end)
    end

    test "a guest's dates and defaults follow the site's language", %{paths: paths} do
      {:ok, _} = PhoenixKit.Settings.update_setting("languages_enabled", "true")

      {:ok, _} =
        PhoenixKit.Settings.update_json_setting(
          "languages_config",
          %{
            "languages" => [
              %{
                "code" => "et-EE",
                "name" => "Estonian",
                "is_default" => true,
                "is_enabled" => true
              }
            ]
          }
        )

      invoice = %PhoenixKitBilling.Invoice{
        invoice_number: "INV-2026-guest",
        billing_details: %{"email" => "guest@example.com"},
        inserted_at: ~U[2026-10-02 00:00:00Z],
        due_date: ~D[2026-10-16],
        currency: "EUR"
      }

      Gettext.with_locale(PhoenixKitWeb.Gettext, "ru", fn ->
        Gettext.with_locale(PhoenixKitBilling.Gettext, "ru", fn ->
          variables = Billing.build_invoice_email_variables(invoice, nil, [])
          opts = Billing.email_send_opts("billing_invoice", variables, nil, %{})

          assert opts[:locale] == "et-EE"
          assert variables["due_date"] == "16 Okt 2026"

          content =
            Content.resolve("billing_invoice", "guest@example.com", variables, opts[:defaults],
              locale: opts[:locale],
              layout: opts[:layout],
              paths: paths
            )

          assert String.starts_with?(content.subject, "Arve ")
          assert content.text =~ "16 Okt 2026"
        end)
      end)
    end

    test "a missing due date omits the payment deadline in both bodies", %{paths: paths} do
      user = user_fixture()
      invoice = %{invoice_fixture(user, []) | due_date: nil}
      variables = Billing.build_invoice_email_variables(invoice, user, [])
      content = render("billing_invoice", variables, user, paths)

      refute content.html =~ "Please pay it by"
      refute content.text =~ "PAYMENT DUE:"
      refute content.text =~ "Due Date:"
      refute content.html =~ "by -."
    end

    test "a customer who prefers et or ru gets the invoice in it", %{paths: paths} do
      for {locale, subject, body} <- [
            {"et", "Arve ", "Tasumisele kuulub"},
            {"ru", "Счёт ", "Итого к оплате"}
          ] do
        user = user_fixture(%{"preferred_locale" => locale})
        invoice = invoice_fixture(user, @hostile_items)

        variables =
          Billing.build_invoice_email_variables(invoice, user,
            invoice_url: "https://example.com/i"
          )

        content = render("billing_invoice", variables, user, paths)

        assert String.starts_with?(content.subject, subject), "#{locale}: #{content.subject}"
        assert content.html =~ body, "#{locale} html"
        refute content.text =~ "{{"
      end
    end

    test "the company's address names its country in the customer's language" do
      PhoenixKit.Settings.update_json_setting("company_info", %{
        "name" => "Acme",
        "city" => "Tallinn",
        "postal_code" => "10117",
        "country" => "EE"
      })

      user = user_fixture(%{"preferred_locale" => "ru"})
      invoice = invoice_fixture(user, @hostile_items)

      variables =
        Gettext.with_locale(PhoenixKitBilling.Gettext, "en", fn ->
          Billing.build_invoice_email_variables(invoice, user, invoice_url: "")
        end)

      assert variables["company_address"] == "Tallinn 10117\nЭстония"
    end

    test "the preview renders each email in the chosen language", %{paths: paths} do
      for entry <- Billing.email_templates(), locale <- ["et", "ru"] do
        {:ok, preview} = Catalog.preview(entry, locale, paths: paths)
        english = entry.defaults.()

        refute preview.content.subject ==
                 Substitution.substitute(english.subject, entry.variables.()),
               "#{entry.name} #{locale}: subject still English"
      end
    end

    test "preview dates follow the chosen language", %{paths: paths} do
      entry = Enum.find(Billing.email_templates(), &(&1.name == "billing_invoice"))

      for {locale, date} <- [{"et", "16 Okt 2026"}, {"ru", "16 Окт 2026"}] do
        {:ok, preview} = Catalog.preview(entry, locale, paths: paths)
        assert preview.content.html =~ date
        assert preview.content.text =~ date
      end
    end
  end
end
