defmodule PhoenixKitBilling.Web.Components.PrintDocument do
  @moduledoc """
  The parts the four printable documents (invoice, receipt, credit note,
  payment confirmation) share: the logo bar, the seller's and the customer's
  details, the footer, the print controls, and the dates, statuses and
  payment methods written in the reader's language.

  Each document keeps its own page and stylesheet; these render inside it and
  use its `meta-section`, `company-name`, `footer-company`, `footer-note` and
  `print-controls` classes. `styles/1` adds the few rules of their own.

  Every label goes through `PhoenixKitBilling.Gettext`, in the locale core's
  admin `on_mount` set from the URL.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitBilling.Gettext

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Invoice

  @doc "The page's `lang`: the base language code of the current locale."
  @spec html_lang() :: String.t()
  def html_lang do
    PhoenixKitBilling.Gettext
    |> Gettext.get_locale()
    |> String.split(["-", "_"])
    |> hd()
  end

  @doc "The rules the shared parts need, for the document's `<head>`."
  def styles(assigns) do
    ~H"""
    <style>
      .document-brand {
        padding: 28px 40px 20px;
        display: flex;
        align-items: center;
        min-height: 56px;
      }

      .document-brand img {
        max-height: 56px;
        max-width: 280px;
        object-fit: contain;
      }

      .document-brand .brand-name {
        font-size: 20px;
        font-weight: 700;
        color: #1f2937;
      }

      .party-line {
        white-space: pre-line;
      }

      #document-seller,
      #document-customer {
        flex: 1 1 0;
        min-width: 0;
        padding-right: 24px;
      }

      #document-details {
        flex: 0 0 auto;
        white-space: nowrap;
      }

      .totals-table {
        width: auto;
        min-width: 300px;
      }

      .totals-table td {
        white-space: nowrap;
      }

      .footer-text {
        white-space: pre-line;
        font-size: 13px;
        color: #374151;
        margin-bottom: 10px;
      }
    </style>
    """
  end

  @doc """
  The logo bar at the top of the document: the document logo, or the company
  name when there is none.
  """
  attr(:logo_url, :string, default: nil)
  attr(:company, :map, required: true)

  def brand(assigns) do
    ~H"""
    <div id="document-brand" class="document-brand">
      <%= if @logo_url do %>
        <img src={@logo_url} alt={@company.name} />
      <% else %>
        <span class="brand-name">{@company.name}</span>
      <% end %>
    </div>
    """
  end

  @doc "Back to the invoice, and Print."
  attr(:back_path, :string, required: true)
  attr(:print_label, :string, required: true)

  def print_controls(assigns) do
    ~H"""
    <div class="print-controls">
      <.link navigate={@back_path} class="btn-back">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path d="m15 18-6-6 6-6" />
        </svg>
        {gettext("Back")}
      </.link>
      <button id="print-button" onclick="window.print()" class="btn-print">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          width="16"
          height="16"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2" /><path d="M6 9V3a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v6" /><rect
            x="6"
            y="14"
            width="12"
            height="8"
            rx="1"
          />
        </svg>
        {@print_label}
      </button>
    </div>
    """
  end

  @doc """
  The seller's details: name, address in its country's order, registration
  number and VAT number when set.
  """
  attr(:company, :map, required: true)
  attr(:title, :string, required: true)

  def seller(assigns) do
    ~H"""
    <div id="document-seller" class="meta-section">
      <h3>{@title}</h3>
      <p>
        <strong>{@company.name}</strong>
        <br />
        <%= for line <- String.split(@company.address || "", "\n", trim: true) do %>
          {line}<br />
        <% end %>
        <%= if present?(@company[:registration]) do %>
          {gettext("Reg. No:")} {@company.registration}<br />
        <% end %>
        <%= if present?(@company.vat) do %>
          {gettext("VAT:")} {@company.vat}
        <% end %>
      </p>
    </div>
    """
  end

  @doc """
  The customer's details from the invoice's billing snapshot, or the
  account's email when the invoice has none.
  """
  attr(:invoice, :map, required: true)
  attr(:title, :string, required: true)

  def customer(assigns) do
    assigns = assign(assigns, :details, assigns.invoice.billing_details || %{})

    ~H"""
    <div id="document-customer" class="meta-section">
      <h3>{@title}</h3>
      <p>
        <%= if map_size(@details) > 0 do %>
          <%= if @details["type"] == "company" do %>
            <span class="company-name">{@details["company_name"]}</span>
            <br />
            <%= if present?(@details["company_vat_number"]) do %>
              {gettext("VAT:")} {@details["company_vat_number"]}<br />
            <% end %>
          <% else %>
            <span class="company-name">{Invoice.payer_name(@details)}</span>
            <br />
          <% end %>
          <span class="party-line">{Billing.format_company_address(@details)}</span>
        <% else %>
          <%= if @invoice.user do %>
            <span class="company-name">{@invoice.user.email}</span>
          <% else %>
            <em>{gettext("No billing information")}</em>
          <% end %>
        <% end %>
      </p>
    </div>
    """
  end

  @doc """
  The footer: the company name, the text about the company set for billing
  documents, and the document's own closing note.
  """
  attr(:company, :map, required: true)
  attr(:footer_text, :string, default: "")
  attr(:note, :string, required: true)
  attr(:class, :string, required: true)

  def footer(assigns) do
    ~H"""
    <div id="document-footer" class={@class}>
      <div class="footer-company">
        <div class="name">{@company.name}</div>
      </div>
      <div :if={present?(@footer_text)} class="footer-text">{@footer_text}</div>
      <div class="footer-note">{@note}</div>
    </div>
    """
  end

  @doc """
  A date in the reader's language — "October 9, 2026", "9 жовтня 2026" —
  or `"-"` for none.
  """
  @spec format_date(Date.t() | DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def format_date(nil), do: "-"

  def format_date(%{day: day, month: month, year: year}) do
    gettext("%{month} %{day}, %{year}", month: month_name(month), day: day, year: year)
  end

  @doc "A date and time in the reader's language, or `\"-\"` for none."
  @spec format_datetime(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def format_datetime(nil), do: "-"

  def format_datetime(datetime) do
    gettext("%{date} at %{time}",
      date: format_date(datetime),
      time: Calendar.strftime(datetime, "%H:%M")
    )
  end

  @doc "An invoice status as a label in the reader's language."
  @spec status_label(String.t() | nil) :: String.t()
  def status_label("draft"), do: pgettext("invoice status", "Draft")
  def status_label("sent"), do: pgettext("invoice status", "Sent")
  def status_label("paid"), do: pgettext("invoice status", "Paid")
  def status_label("overdue"), do: pgettext("invoice status", "Overdue")
  def status_label("void"), do: pgettext("invoice status", "Void")
  def status_label(status) when is_binary(status), do: String.capitalize(status)
  def status_label(_status), do: ""

  @doc """
  A payment method as a label: a bank transfer in the reader's language, a
  provider by its name.
  """
  @spec payment_method_label(String.t() | nil) :: String.t()
  def payment_method_label(method) when method in [nil, "", "bank"], do: gettext("Bank Transfer")
  def payment_method_label("paypal"), do: "PayPal"
  def payment_method_label("everypay"), do: "EveryPay"
  def payment_method_label(method) when is_binary(method), do: String.capitalize(method)

  # Month names as a date writes them, which in many languages is not the
  # nominative a calendar heading uses ("9 жовтня", not "9 жовтень").
  defp month_name(1), do: pgettext("date", "January")
  defp month_name(2), do: pgettext("date", "February")
  defp month_name(3), do: pgettext("date", "March")
  defp month_name(4), do: pgettext("date", "April")
  defp month_name(5), do: pgettext("date", "May")
  defp month_name(6), do: pgettext("date", "June")
  defp month_name(7), do: pgettext("date", "July")
  defp month_name(8), do: pgettext("date", "August")
  defp month_name(9), do: pgettext("date", "September")
  defp month_name(10), do: pgettext("date", "October")
  defp month_name(11), do: pgettext("date", "November")
  defp month_name(12), do: pgettext("date", "December")

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
