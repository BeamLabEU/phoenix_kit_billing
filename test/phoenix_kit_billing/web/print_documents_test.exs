defmodule PhoenixKitBilling.Web.PrintDocumentsTest do
  @moduledoc """
  What the four printable documents say, and in which language: every label
  comes from this module's Gettext backend, the seller and the customer sit
  under the right headings, the seller's address follows its country's
  order, and the footer carries the text set under Billing → Settings.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.DocumentBranding
  alias PhoenixKitBilling.Web.Components.PrintDocument

  @company %{
    "name" => "ФОП Тестовий Продавець",
    "address_line1" => "вул. Тестова, 1",
    "address_line2" => "",
    "city" => "м. Полтава",
    "state" => "",
    "postal_code" => "36000",
    "country" => "UA",
    "vat_number" => "",
    "registration_number" => "1234567890"
  }

  @footer "«Acme» — товари для дому.\nЦіни кінцеві: продавець не є платником ПДВ."

  setup %{conn: conn} do
    Settings.update_json_setting("company_info", @company)

    Settings.update_json_setting("company_bank_accounts", %{
      "accounts" => [
        %{
          "uuid" => UUIDv7.generate(),
          "label" => "",
          "bank_name" => "АТ КБ «ПРИВАТБАНК»",
          "iban" => "UA000000000000000000000000000",
          "swift" => "",
          "primary" => true
        }
      ]
    })

    Settings.update_setting("billing_bank_account_holder", "ФОП Тестовий Продавець")
    Settings.update_setting(DocumentBranding.footer_key(), @footer)

    user = fixture_user()
    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    {:ok, conn: put_test_scope(conn, scope), user: user}
  end

  defp sent_invoice(user) do
    {:ok, invoice} =
      Billing.create_invoice(user.uuid, %{
        subtotal: Decimal.new("150.00"),
        total: Decimal.new("150.00"),
        currency: "UAH",
        line_items: [
          %{"name" => "Мило", "quantity" => 3, "unit_price" => "50.00", "total" => "150.00"}
        ],
        billing_details: %{
          "type" => "individual",
          "first_name" => "Олена",
          "last_name" => "Покупець",
          "address_line1" => "вул. Покупця, 2",
          "city" => "м. Київ",
          "postal_code" => "01001",
          "country" => "UA"
        }
      })

    {:ok, invoice, _} =
      Billing.send_invoice(invoice, to_email: "customer@example.com", send_email: false)

    invoice
  end

  defp text(html, selector) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  describe "invoice, in Russian" do
    setup %{conn: conn, user: user} do
      invoice = sent_invoice(user)
      {:ok, _view, html} = live(put_test_locale(conn, "ru"), print_path(invoice))
      {:ok, html: html, invoice: invoice}
    end

    test "is a Russian document", %{html: html} do
      assert text(html, "#document-title") == "Счёт"
      assert text(html, "#print-button") == "Распечатать счёт"
      refute html =~ "Bill To"
      refute html =~ "INVOICE"
      refute html =~ "Description"
    end

    test "puts the seller under From and the customer under Bill To", %{html: html} do
      seller = text(html, "#document-seller")
      customer = text(html, "#document-customer")

      assert seller =~ "Поставщик"
      assert seller =~ "ФОП Тестовий Продавець"
      assert seller =~ "36000, м. Полтава, вул. Тестова, 1"
      assert seller =~ "Украина"
      assert seller =~ "1234567890"

      assert customer =~ "Плательщик"
      assert customer =~ "Олена Покупець"
      assert customer =~ "01001, м. Київ, вул. Покупця, 2"
    end

    test "shows the bank details it has, with the account holder", %{html: html} do
      bank = text(html, "#document-bank-details")

      assert bank =~ "Получатель"
      assert bank =~ "UA000000000000000000000000000"
      refute bank =~ "SWIFT"
    end

    test "dates the document in Russian", %{html: html, invoice: invoice} do
      month =
        Enum.at(
          ~w(января февраля марта апреля мая июня июля августа сентября октября ноября декабря),
          invoice.inserted_at.month - 1
        )

      assert text(html, "#document-details") =~ "#{invoice.inserted_at.day} #{month}"
    end

    test "carries the footer text and no company address in the footer", %{html: html} do
      footer = text(html, "#document-footer")

      assert footer =~ "«Acme» — товари для дому."
      assert footer =~ "Ціни кінцеві: продавець не є платником ПДВ."
      refute footer =~ "вул. Тестова"
    end

    test "has the company name in the header without a logo", %{html: html} do
      assert text(html, "#document-brand") =~ "ФОП Тестовий Продавець"
    end
  end

  test "an invoice still prints in English", %{conn: conn, user: user} do
    invoice = sent_invoice(user)
    {:ok, _view, html} = live(put_test_locale(conn, "en"), print_path(invoice))

    assert text(html, "#document-title") == "Invoice"
    assert text(html, "#document-seller") =~ "From"
    assert text(html, "#document-customer") =~ "Bill To"
    assert text(html, "#document-seller") =~ "Ukraine"
  end

  test "a receipt is a Russian document", %{conn: conn, user: user} do
    invoice = sent_invoice(user)
    {:ok, invoice} = Billing.mark_invoice_paid(invoice)

    {:ok, _view, html} =
      live(put_test_locale(conn, "ru"), "/en/admin/billing/invoices/#{invoice.uuid}/receipt")

    assert text(html, "#document-title") == "Квитанция"
    assert text(html, "#document-seller") =~ "ФОП Тестовий Продавець"
    assert text(html, "#document-customer") =~ "Олена Покупець"
    assert text(html, "#document-footer") =~ "Ціни кінцеві"
    refute html =~ "Received From"
    refute html =~ "Payment Confirmed"
  end

  test "a credit note is a Russian document", %{conn: conn, user: user} do
    invoice = sent_invoice(user)
    {:ok, _payment} = Billing.record_payment(invoice, %{amount: "150.00"}, nil)
    paid = Billing.get_invoice!(invoice.uuid)
    {:ok, refund} = Billing.record_refund(paid, %{amount: "50.00", description: "брак"}, nil)

    {:ok, _view, html} =
      live(
        put_test_locale(conn, "ru"),
        "/en/admin/billing/invoices/#{invoice.uuid}/credit-note/#{refund.uuid}"
      )

    assert text(html, "#document-title") == "Кредит-нота"
    assert text(html, "#document-seller") =~ "ФОП Тестовий Продавець"
    assert text(html, "#document-footer") =~ "Ціни кінцеві"
    refute html =~ "Refund Details"
  end

  test "a payment confirmation is a Russian document", %{conn: conn, user: user} do
    invoice = sent_invoice(user)
    {:ok, payment} = Billing.record_payment(invoice, %{amount: "50.00"}, nil)

    {:ok, _view, html} =
      live(
        put_test_locale(conn, "ru"),
        "/en/admin/billing/invoices/#{invoice.uuid}/payment-confirmation/#{payment.uuid}"
      )

    assert text(html, "#document-title") == "Подтверждение оплаты"
    assert text(html, "#document-seller") =~ "ФОП Тестовий Продавець"
    assert text(html, "#document-footer") =~ "Ціни кінцеві"
    refute html =~ "Remaining Balance"
  end

  test "the header shows the document logo when there is one" do
    html =
      render_component(&PrintDocument.brand/1,
        logo_url: "/file/abc/original/token",
        company: %{name: "Acme"}
      )

    assert html =~ ~s(<img src="/file/abc/original/token" alt="Acme")
    refute html =~ "brand-name"
  end

  test "the header has no empty band without a logo or a company name" do
    html = render_component(&PrintDocument.brand/1, logo_url: nil, company: %{name: ""})

    refute html =~ "document-brand"
  end

  defp print_path(invoice), do: "/en/admin/billing/invoices/#{invoice.uuid}/print"
end
