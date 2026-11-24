defmodule PhoenixKitBilling.Web.Components.StatusBadgesTest do
  @moduledoc """
  The order and invoice status badges write the status in the reader's
  language. Each status the schema allows needs its own translation: the
  expected tables below are compared with the schema's own list, so a status
  added there without a label fails here instead of staying English on a
  translated site.

  No database — the components only read their assigns.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Order
  alias PhoenixKitBilling.Web.Components.InvoiceStatusBadge
  alias PhoenixKitBilling.Web.Components.OrderStatusBadge

  @order_labels %{
    "de" => %{
      "draft" => "Entwurf",
      "pending" => "Ausstehend",
      "confirmed" => "Bestätigt",
      "paid" => "Bezahlt",
      "cancelled" => "Storniert",
      "refunded" => "Erstattet"
    },
    "fr" => %{
      "draft" => "Brouillon",
      "pending" => "En attente",
      "confirmed" => "Confirmée",
      "paid" => "Payée",
      "cancelled" => "Annulé",
      "refunded" => "Remboursée"
    }
  }

  @invoice_labels %{
    "de" => %{
      "draft" => "Entwurf",
      "sent" => "Gesendet",
      "paid" => "Bezahlt",
      "void" => "Storniert",
      "overdue" => "Überfällig"
    },
    "fr" => %{
      "draft" => "Brouillon",
      "sent" => "Envoyée",
      "paid" => "Payée",
      "void" => "Annulée",
      "overdue" => "En retard"
    }
  }

  setup do
    original = Gettext.get_locale(PhoenixKitBilling.Gettext)
    on_exit(fn -> Gettext.put_locale(PhoenixKitBilling.Gettext, original) end)
    :ok
  end

  defp badge_text(fun, status) do
    fun
    |> render_component(status: status)
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("span.badge")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp order_badge(status), do: badge_text(&OrderStatusBadge.order_status_badge/1, status)
  defp invoice_badge(status), do: badge_text(&InvoiceStatusBadge.invoice_status_badge/1, status)

  describe "order status badge" do
    test "the tables list exactly the statuses the order schema allows" do
      for {locale, labels} <- @order_labels do
        assert Enum.sort(Map.keys(labels)) == Enum.sort(Order.statuses()), locale
      end
    end

    test "English is the capitalised status, as before" do
      Gettext.put_locale(PhoenixKitBilling.Gettext, "en")

      for status <- Order.statuses() do
        assert order_badge(status) == String.capitalize(status)
      end
    end

    for locale <- ~w(de fr) do
      test "every status reads in #{locale}" do
        Gettext.put_locale(PhoenixKitBilling.Gettext, unquote(locale))

        for {status, label} <- Map.fetch!(@order_labels, unquote(locale)) do
          assert order_badge(status) == label,
                 "#{unquote(locale)}: order status #{inspect(status)}"
        end
      end
    end

    test "an unknown status falls back to the capitalised raw value" do
      Gettext.put_locale(PhoenixKitBilling.Gettext, "de")

      assert order_badge("on_hold") == "On_hold"
      assert order_badge("") == ""
    end
  end

  describe "invoice status badge" do
    test "the tables list exactly the statuses the invoice schema allows" do
      for {locale, labels} <- @invoice_labels do
        assert Enum.sort(Map.keys(labels)) == Enum.sort(Invoice.statuses()), locale
      end
    end

    test "English is the capitalised status, as before" do
      Gettext.put_locale(PhoenixKitBilling.Gettext, "en")

      for status <- Invoice.statuses() do
        assert invoice_badge(status) == String.capitalize(status)
      end
    end

    for locale <- ~w(de fr) do
      test "every status reads in #{locale}" do
        Gettext.put_locale(PhoenixKitBilling.Gettext, unquote(locale))

        for {status, label} <- Map.fetch!(@invoice_labels, unquote(locale)) do
          assert invoice_badge(status) == label,
                 "#{unquote(locale)}: invoice status #{inspect(status)}"
        end
      end
    end

    test "an unknown status falls back to the capitalised raw value" do
      Gettext.put_locale(PhoenixKitBilling.Gettext, "fr")

      assert invoice_badge("disputed") == "Disputed"
    end
  end
end
