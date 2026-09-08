defmodule PhoenixKitBilling.Web.Settings do
  @moduledoc """
  Billing settings LiveView for the billing module.

  Provides configuration interface for billing module settings.
  Company and bank information is now managed in Organization Settings.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitBilling.Web.Components.SettingsTabs

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.CountryData
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Web.Authz
  alias PhoenixKitWeb.Live.Settings.Organization

  @impl true
  def mount(_params, _session, socket) do
    project_title = Settings.get_project_title()
    billing_enabled = Billing.enabled?()

    socket =
      socket
      |> assign(:page_title, gettext("Billing Settings"))
      |> assign(:project_title, project_title)
      |> assign(:billing_enabled, billing_enabled)
      |> load_settings()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_settings(socket) do
    # Get company info from Organization settings (with fallback to legacy keys)
    company_info = Organization.get_company_info()
    bank_details = Organization.get_bank_details()
    company_country = company_info["country"] || ""

    socket
    # General settings
    #
    # §3.3: the shop's base currency is the `is_default` row of
    # phoenix_kit_currencies (PhoenixKitBilling.get_base_currency/0), set
    # via the currencies admin page — NOT this settings form.
    # `billing_default_currency` used to back a "Default Currency" select
    # here that wrote a setting nothing else read even before this change
    # (§2.3); the select and its write are removed together with this
    # assign rather than left pointing at a dead value.
    |> assign(:invoice_prefix, Settings.get_setting("billing_invoice_prefix", "INV"))
    |> assign(:order_prefix, Settings.get_setting("billing_order_prefix", "ORD"))
    |> assign(:receipt_prefix, Settings.get_setting("billing_receipt_prefix", "RCP"))
    |> assign(:invoice_due_days, Settings.get_setting("billing_invoice_due_days", "14"))
    |> assign(:tax_enabled, Settings.get_setting("billing_tax_enabled", "false") == "true")
    |> assign(:tax_rate, Settings.get_setting("billing_default_tax_rate", "0"))
    # Company info (from consolidated source)
    |> assign(:company_info, company_info)
    |> assign(:company_address_formatted, Billing.format_company_address(company_info))
    |> assign(:company_country_name, get_country_name(company_country))
    |> assign(:company_country, company_country)
    # For suggested tax rate
    |> assign_suggested_tax_rate()
    # Bank details (from consolidated source)
    |> assign(:bank_details, bank_details)
  end

  # Helper to get country name from code
  defp get_country_name(""), do: ""
  defp get_country_name(nil), do: ""

  defp get_country_name(country_code) do
    case BeamLabCountries.get(country_code) do
      nil -> country_code
      country -> country.name
    end
  end

  @impl true
  def handle_event("save_general", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("save_general", params, socket)
    end)
  end

  @impl true
  def handle_event("tax_rate_changed", %{"tax_rate" => tax_rate}, socket) do
    current_rate = parse_tax_rate(tax_rate)
    country_code = socket.assigns.company_country

    suggested_rate =
      if country_code != "" do
        rate = CountryData.get_standard_vat_percent(country_code)
        if rate == current_rate, do: nil, else: rate
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:tax_rate, tax_rate)
     |> assign(:suggested_tax_rate, suggested_rate)}
  end

  @impl true
  def handle_event("apply_suggested_tax", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("apply_suggested_tax", params, socket)
    end)
  end

  # Suggested tax rate helper

  defp assign_suggested_tax_rate(socket) do
    country_code = socket.assigns.company_country
    current_rate = parse_tax_rate(socket.assigns.tax_rate)

    suggested_rate =
      if country_code != "" do
        rate = CountryData.get_standard_vat_percent(country_code)
        # Hide suggestion if it matches current rate
        if rate == current_rate, do: nil, else: rate
      else
        nil
      end

    assign(socket, :suggested_tax_rate, suggested_rate)
  end

  defp parse_tax_rate(rate) when is_binary(rate) do
    case Float.parse(rate) do
      {value, _} -> if value == trunc(value), do: trunc(value), else: value
      :error -> 0
    end
  end

  defp parse_tax_rate(rate) when is_number(rate), do: rate
  defp parse_tax_rate(_), do: 0

  defp gated_event("save_general", params, socket) do
    # Convert checkbox value to "true"/"false" string
    tax_enabled = if params["tax_enabled"] == "true", do: "true", else: "false"

    settings = [
      # §3.3: no "default currency" setting is written here anymore — the
      # base currency is the currencies admin page's is_default row.
      {"billing_invoice_prefix", params["invoice_prefix"]},
      {"billing_order_prefix", params["order_prefix"]},
      {"billing_receipt_prefix", params["receipt_prefix"]},
      {"billing_invoice_due_days", params["invoice_due_days"]},
      {"billing_tax_enabled", tax_enabled},
      {"billing_default_tax_rate", params["tax_rate"]}
    ]

    Enum.each(settings, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> load_settings()
     |> put_flash(:info, gettext("General settings saved"))}
  end

  defp gated_event("apply_suggested_tax", _params, socket) do
    case socket.assigns.suggested_tax_rate do
      nil ->
        {:noreply, socket}

      rate ->
        {:noreply,
         socket
         |> assign(:tax_rate, to_string(rate))
         |> assign(:suggested_tax_rate, nil)}
    end
  end
end
