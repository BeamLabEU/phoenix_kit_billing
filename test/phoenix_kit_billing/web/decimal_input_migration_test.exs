defmodule PhoenixKitBilling.Web.DecimalInputMigrationTest do
  @moduledoc """
  Coverage for the `<.decimal_input>` migration: every site that used to be a
  browser `type="number"` control or a hand-rolled `Decimal.parse`/`Float.parse`
  now accepts a comma OR a dot, unrounded, and rejects garbage the same way it
  did before (a changeset error, or a safe fallback — never a crash).
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitBilling.Test.Repo

  setup %{conn: conn} do
    Settings.update_setting("billing_enabled", "true")
    %{conn: put_test_scope(conn, fake_scope())}
  end

  describe "billing settings — default tax rate" do
    test "a comma rate is stored canonically (dot) for later reads", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/settings/billing")

      view
      |> form("form[phx-submit=save_general]", %{
        "invoice_prefix" => "INV",
        "receipt_prefix" => "RCP",
        "invoice_due_days" => "14",
        "tax_enabled" => "true",
        "tax_rate" => "20,5"
      })
      |> render_submit()

      assert Settings.get_setting("billing_default_tax_rate") == "20.5"
    end

    test "a dot rate round-trips unrounded", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/settings/billing")

      view
      |> form("form[phx-submit=save_general]", %{
        "invoice_prefix" => "INV",
        "receipt_prefix" => "RCP",
        "invoice_due_days" => "14",
        "tax_enabled" => "true",
        "tax_rate" => "7.25"
      })
      |> render_submit()

      assert Settings.get_setting("billing_default_tax_rate") == "7.25"
    end

    test "garbage is stored as-is, same as before the migration (reader falls back to 0)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/en/admin/settings/billing")

      view
      |> form("form[phx-submit=save_general]", %{
        "invoice_prefix" => "INV",
        "receipt_prefix" => "RCP",
        "invoice_due_days" => "14",
        "tax_enabled" => "true",
        "tax_rate" => "not-a-number"
      })
      |> render_submit()

      assert Settings.get_setting("billing_default_tax_rate") == "not-a-number"
    end

    test "a blank rate takes the same non-rejected path as before the migration", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/settings/billing")

      html =
        view
        |> form("form[phx-submit=save_general]", %{
          "invoice_prefix" => "INV",
          "receipt_prefix" => "RCP",
          "invoice_due_days" => "14",
          "tax_enabled" => "true",
          "tax_rate" => ""
        })
        |> render_submit()

      # Blank is neither below the 0-100 bound nor above it, so
      # normalize_tax_rate/1's :below_min/:above_max guard does not fire —
      # the submit takes the same success path a garbage value does, not
      # the out-of-range rejection.
      assert html =~ "General settings saved"
      refute html =~ "Tax rate must be between 0 and 100"
    end

    test "a rejected out-of-range submit preserves the other unsaved field edits in the form",
         %{conn: conn} do
      Settings.update_setting("billing_invoice_prefix", "INV")
      Settings.update_setting("billing_order_prefix", "ORD")
      Settings.update_setting("billing_default_tax_rate", "20")

      {:ok, view, _html} = live(conn, "/en/admin/settings/billing")

      html =
        view
        |> form("form[phx-submit=save_general]", %{
          "invoice_prefix" => "NEWINV",
          "order_prefix" => "NEWORD",
          "receipt_prefix" => "RCP",
          "invoice_due_days" => "30",
          "tax_enabled" => "true",
          "tax_rate" => "500"
        })
        |> render_submit()

      # Rejected: nothing persisted...
      assert Settings.get_setting("billing_invoice_prefix") == "INV"
      assert Settings.get_setting("billing_order_prefix") == "ORD"
      assert Settings.get_setting("billing_invoice_due_days") == "14"

      # ...but the other edits the user just typed are still on screen,
      # not reverted to the stale server values above.
      assert html =~ "NEWINV"
      assert html =~ "NEWORD"
      assert html =~ "value=\"30\""
    end

    test "a rate above 100 is rejected, same as the old browser min/max guard", %{conn: conn} do
      Settings.update_setting("billing_default_tax_rate", "20")

      {:ok, view, _html} = live(conn, "/en/admin/settings/billing")

      html =
        view
        |> form("form[phx-submit=save_general]", %{
          "invoice_prefix" => "INV",
          "receipt_prefix" => "RCP",
          "invoice_due_days" => "14",
          "tax_enabled" => "true",
          "tax_rate" => "500"
        })
        |> render_submit()

      assert html =~ "Tax rate must be between 0 and 100"
      assert Settings.get_setting("billing_default_tax_rate") == "20"
    end

    test "a negative rate is rejected, same as the old browser min/max guard", %{conn: conn} do
      Settings.update_setting("billing_default_tax_rate", "20")

      {:ok, view, _html} = live(conn, "/en/admin/settings/billing")

      html =
        view
        |> form("form[phx-submit=save_general]", %{
          "invoice_prefix" => "INV",
          "receipt_prefix" => "RCP",
          "invoice_due_days" => "14",
          "tax_enabled" => "true",
          "tax_rate" => "-5"
        })
        |> render_submit()

      assert html =~ "Tax rate must be between 0 and 100"
      assert Settings.get_setting("billing_default_tax_rate") == "20"
    end
  end

  describe "currencies — exchange rate" do
    setup do
      PhoenixKit.Cache.clear(:billing_currencies)
      Repo.delete_all(Currency)

      # Non-empty so only the header "Add Currency" button renders — the
      # empty-state one shares the same phx-click and would make
      # `element/2` ambiguous.
      {:ok, _base} =
        Billing.create_currency(%{
          code: "EUR",
          name: "Euro",
          symbol: "€",
          is_default: true,
          exchange_rate: "1.0"
        })

      :ok
    end

    test "a comma rate saves and normalizes to a dot decimal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/currencies")

      view |> element("button[phx-click=show_add_form]") |> render_click()

      view
      |> form("#currency-form", %{
        "currency" => %{
          "code" => "USD",
          "name" => "Dollar",
          "symbol" => "$",
          "exchange_rate" => "1,25"
        }
      })
      |> render_submit()

      currency = Repo.get_by(Currency, code: "USD")
      assert Decimal.equal?(currency.exchange_rate, Decimal.new("1.25"))
    end

    test "a dot rate saves unrounded", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/currencies")

      view |> element("button[phx-click=show_add_form]") |> render_click()

      view
      |> form("#currency-form", %{
        "currency" => %{
          "code" => "GBP",
          "name" => "Pound",
          "symbol" => "£",
          "exchange_rate" => "0.876543"
        }
      })
      |> render_submit()

      currency = Repo.get_by(Currency, code: "GBP")
      assert Decimal.equal?(currency.exchange_rate, Decimal.new("0.876543"))
    end

    test "garbage is rejected on the changeset, same as before", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/currencies")

      view |> element("button[phx-click=show_add_form]") |> render_click()

      view
      |> form("#currency-form", %{
        "currency" => %{
          "code" => "AUD",
          "name" => "Australian Dollar",
          "symbol" => "A$",
          "exchange_rate" => "abc"
        }
      })
      |> render_submit()

      # Same as before the migration: the exchange rate field has no
      # inline error display, but a garbage rate still fails the
      # changeset's `:decimal` cast and nothing gets persisted.
      assert Process.alive?(view.pid)
      refute Repo.get_by(Currency, code: "AUD")
    end
  end

  describe "subscription type — price" do
    test "a comma price saves unrounded", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/subscription-types/new")

      view
      |> form("form", %{
        "subscription_type" => %{"name" => "Pro", "slug" => "pro-comma", "price" => "19,90"}
      })
      |> render_submit()

      {:ok, type} = Billing.get_subscription_type_by_slug("pro-comma")
      assert Decimal.equal?(type.price, Decimal.new("19.90"))
    end

    test "a dot price saves unrounded", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/subscription-types/new")

      view
      |> form("form", %{
        "subscription_type" => %{"name" => "Basic", "slug" => "basic-dot", "price" => "12.34"}
      })
      |> render_submit()

      {:ok, type} = Billing.get_subscription_type_by_slug("basic-dot")
      assert Decimal.equal?(type.price, Decimal.new("12.34"))
    end

    test "garbage price is rejected inline instead of crashing the process", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/subscription-types/new")

      rendered =
        view
        |> form("form", %{
          "subscription_type" => %{"name" => "Bad", "slug" => "bad-price", "price" => "abc"}
        })
        |> render_submit()

      assert Process.alive?(view.pid)
      assert rendered =~ "is invalid"

      assert Billing.get_subscription_type_by_slug("bad-price") ==
               {:error, :subscription_type_not_found}
    end

    # Core's <.input> and <.decimal_input> render their own required marker, so
    # a label string ending in " *" showed two asterisks.
    test "required labels carry exactly one asterisk", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/billing/subscription-types/new")

      doc = LazyHTML.from_fragment(html)

      for id <- ["subscription_type_name", "subscription_type_slug", "subscription_type_price"] do
        label_text =
          doc
          |> LazyHTML.query("label[for='#{id}']")
          |> LazyHTML.text()

        assert label_text =~ "*", "expected a required marker on #{id}"
        refute label_text =~ ~r/\*.*\*/s, "label for #{id} renders two asterisks"
      end
    end
  end

  describe "invoice payment / refund amounts" do
    setup %{conn: conn} do
      user = fixture_user()
      scope = fake_scope(user_uuid: user.uuid, email: user.email)
      conn = put_test_scope(conn, scope)

      {:ok, invoice} =
        Billing.create_invoice(user.uuid, %{total: Decimal.new("100.00"), currency: "EUR"})

      {:ok, invoice, _email_result} =
        Billing.send_invoice(invoice, to_email: "customer@example.com", send_email: false)

      %{conn: conn, invoice: invoice, user: user}
    end

    test "a comma payment amount is recorded unrounded", %{conn: conn, invoice: invoice} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      view |> element("button[phx-click=open_payment_modal]") |> render_click()

      payment_form =
        form(view, "form[phx-submit=record_payment]", %{
          "amount" => "50,25",
          "payment_method" => "bank",
          "description" => ""
        })

      render_change(payment_form)
      render_submit(payment_form)

      reloaded = Billing.get_invoice(invoice.uuid)
      assert Decimal.equal?(reloaded.paid_amount, Decimal.new("50.25"))
    end

    test "a dot refund amount is recorded unrounded", %{conn: conn, invoice: invoice} do
      {:ok, _payment} = Billing.record_payment(invoice, %{amount: "100.00"}, nil)

      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      view |> element("button[phx-click=open_refund_modal]") |> render_click()

      refund_form =
        form(view, "form[phx-submit=record_refund]", %{
          "amount" => "12.34",
          "payment_method" => "bank",
          "description" => "partial refund"
        })

      render_change(refund_form)
      render_submit(refund_form)

      reloaded = Billing.get_invoice(invoice.uuid)
      assert Decimal.equal?(reloaded.paid_amount, Decimal.new("87.66"))
    end

    test "a garbage payment amount is rejected as before (:invalid_amount)", %{
      conn: conn,
      invoice: invoice
    } do
      {:ok, view, _html} = live(conn, "/en/admin/billing/invoices/#{invoice.uuid}")

      view |> element("button[phx-click=open_payment_modal]") |> render_click()

      payment_form =
        form(view, "form[phx-submit=record_payment]", %{
          "amount" => "not-a-number",
          "payment_method" => "bank",
          "description" => ""
        })

      render_change(payment_form)
      html = render_submit(payment_form)

      assert html =~ "Invalid payment amount"

      reloaded = Billing.get_invoice(invoice.uuid)
      assert Decimal.equal?(reloaded.paid_amount, Decimal.new("0"))
    end
  end

  describe "order line item — unit price" do
    setup %{conn: conn} do
      user = fixture_user()

      {:ok, _profile} =
        Billing.create_billing_profile(user, %{
          "type" => "individual",
          "first_name" => "Ada",
          "last_name" => "Lovelace"
        })

      %{conn: conn, user: user}
    end

    test "a comma unit price saves unrounded on the created order", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/en/admin/billing/orders/new")

      view
      |> element("select[name='user_uuid']")
      |> render_change(%{"user_uuid" => user.uuid})

      view
      |> element("input[name='line_item_0_name']")
      |> render_blur(%{"value" => "Widget"})

      view
      |> element("input[name='line_item_0_price']")
      |> render_blur(%{"value" => "9,99"})

      view
      |> form("form[phx-submit=save]")
      |> render_submit()

      [order] = Billing.list_user_orders(user.uuid)
      [item] = order.line_items
      assert Decimal.equal?(Decimal.new(item["unit_price"]), Decimal.new("9.99"))
    end
  end
end
