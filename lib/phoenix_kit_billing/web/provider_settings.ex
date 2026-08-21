defmodule PhoenixKitBilling.Web.ProviderSettings do
  @moduledoc """
  Payment provider settings LiveView for the billing module.

  Provides configuration interface for Stripe, PayPal, Razorpay, and EveryPay
  payment providers.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  alias PhoenixKitBilling.Web.Authz
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitBilling.Web.Components.SettingsTabs

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Providers

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:page_title, gettext("Payment Providers"))
        |> assign(:project_title, project_title)
        |> load_provider_settings()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/admin/billing/settings"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_provider_settings(socket) do
    socket
    # Stripe settings
    |> assign(:stripe_enabled, Settings.get_setting("billing_stripe_enabled", "false") == "true")
    |> assign(:stripe_secret_key, Settings.get_setting("billing_stripe_secret_key", ""))
    |> assign(:stripe_publishable_key, Settings.get_setting("billing_stripe_publishable_key", ""))
    |> assign(:stripe_webhook_secret, Settings.get_setting("billing_stripe_webhook_secret", ""))
    |> assign(:stripe_webhook_url, Routes.url("/webhooks/billing/stripe"))
    # PayPal settings
    |> assign(:paypal_enabled, Settings.get_setting("billing_paypal_enabled", "false") == "true")
    |> assign(:paypal_client_id, Settings.get_setting("billing_paypal_client_id", ""))
    |> assign(:paypal_client_secret, Settings.get_setting("billing_paypal_client_secret", ""))
    |> assign(:paypal_webhook_id, Settings.get_setting("billing_paypal_webhook_id", ""))
    |> assign(:paypal_mode, Settings.get_setting("billing_paypal_mode", "sandbox"))
    |> assign(:paypal_webhook_url, Routes.url("/webhooks/billing/paypal"))
    # Razorpay settings
    |> assign(
      :razorpay_enabled,
      Settings.get_setting("billing_razorpay_enabled", "false") == "true"
    )
    |> assign(:razorpay_key_id, Settings.get_setting("billing_razorpay_key_id", ""))
    |> assign(:razorpay_key_secret, Settings.get_setting("billing_razorpay_key_secret", ""))
    |> assign(
      :razorpay_webhook_secret,
      Settings.get_setting("billing_razorpay_webhook_secret", "")
    )
    |> assign(:razorpay_webhook_url, Routes.url("/webhooks/billing/razorpay"))
    # EveryPay settings
    |> assign(
      :everypay_enabled,
      Settings.get_setting("billing_everypay_enabled", "false") == "true"
    )
    |> assign(:everypay_api_username, Settings.get_setting("billing_everypay_api_username", ""))
    |> assign(:everypay_api_secret, Settings.get_setting("billing_everypay_api_secret", ""))
    |> assign(:everypay_account_name, Settings.get_setting("billing_everypay_account_name", ""))
    |> assign(:everypay_mode, Settings.get_setting("billing_everypay_mode", "test"))
    |> assign(:everypay_webhook_url, Routes.url("/webhooks/billing/everypay"))
    # Provider availability
    |> assign(:available_providers, Providers.list_available_providers())
  end

  @impl true
  def handle_event("toggle_stripe", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_stripe", params, socket)
    end)
  end

  @impl true
  def handle_event("save_stripe", params, socket) do
    Authz.authorize(socket, :manage_settings, fn -> gated_event("save_stripe", params, socket) end)
  end

  @impl true
  def handle_event("toggle_paypal", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_paypal", params, socket)
    end)
  end

  @impl true
  def handle_event("save_paypal", params, socket) do
    Authz.authorize(socket, :manage_settings, fn -> gated_event("save_paypal", params, socket) end)
  end

  @impl true
  def handle_event("toggle_razorpay", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_razorpay", params, socket)
    end)
  end

  @impl true
  def handle_event("save_razorpay", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("save_razorpay", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_everypay", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_everypay", params, socket)
    end)
  end

  @impl true
  def handle_event("save_everypay", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("save_everypay", params, socket)
    end)
  end

  # Helper to mask sensitive keys
  def mask_key(nil), do: ""
  def mask_key(""), do: ""

  def mask_key(key) when is_binary(key) do
    len = String.length(key)

    if len > 8 do
      String.slice(key, 0, 4) <> String.duplicate("•", len - 8) <> String.slice(key, -4, 4)
    else
      String.duplicate("•", len)
    end
  end

  def has_credentials?(key) when is_binary(key), do: key != ""
  def has_credentials?(_), do: false

  defp gated_event("toggle_stripe", _params, socket) do
    new_enabled = !socket.assigns.stripe_enabled
    Settings.update_setting("billing_stripe_enabled", to_string(new_enabled))

    {:noreply,
     socket
     |> assign(:stripe_enabled, new_enabled)
     |> assign(:available_providers, Providers.list_available_providers())
     |> put_flash(
       :info,
       if(new_enabled, do: gettext("Stripe enabled"), else: gettext("Stripe disabled"))
     )}
  end

  defp gated_event("save_stripe", params, socket) do
    settings = [
      {"billing_stripe_secret_key", params["secret_key"] || ""},
      {"billing_stripe_publishable_key", params["publishable_key"] || ""},
      {"billing_stripe_webhook_secret", params["webhook_secret"] || ""}
    ]

    Enum.each(settings, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> load_provider_settings()
     |> put_flash(:info, gettext("Stripe settings saved"))}
  end

  defp gated_event("toggle_paypal", _params, socket) do
    new_enabled = !socket.assigns.paypal_enabled
    Settings.update_setting("billing_paypal_enabled", to_string(new_enabled))

    {:noreply,
     socket
     |> assign(:paypal_enabled, new_enabled)
     |> assign(:available_providers, Providers.list_available_providers())
     |> put_flash(
       :info,
       if(new_enabled, do: gettext("PayPal enabled"), else: gettext("PayPal disabled"))
     )}
  end

  defp gated_event("save_paypal", params, socket) do
    settings = [
      {"billing_paypal_client_id", params["client_id"] || ""},
      {"billing_paypal_client_secret", params["client_secret"] || ""},
      {"billing_paypal_webhook_id", params["webhook_id"] || ""},
      {"billing_paypal_mode", params["mode"] || "sandbox"}
    ]

    Enum.each(settings, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> load_provider_settings()
     |> put_flash(:info, gettext("PayPal settings saved"))}
  end

  defp gated_event("toggle_razorpay", _params, socket) do
    new_enabled = !socket.assigns.razorpay_enabled
    Settings.update_setting("billing_razorpay_enabled", to_string(new_enabled))

    {:noreply,
     socket
     |> assign(:razorpay_enabled, new_enabled)
     |> assign(:available_providers, Providers.list_available_providers())
     |> put_flash(
       :info,
       if(new_enabled, do: gettext("Razorpay enabled"), else: gettext("Razorpay disabled"))
     )}
  end

  defp gated_event("save_razorpay", params, socket) do
    settings = [
      {"billing_razorpay_key_id", params["key_id"] || ""},
      {"billing_razorpay_key_secret", params["key_secret"] || ""},
      {"billing_razorpay_webhook_secret", params["webhook_secret"] || ""}
    ]

    Enum.each(settings, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> load_provider_settings()
     |> put_flash(:info, gettext("Razorpay settings saved"))}
  end

  defp gated_event("toggle_everypay", _params, socket) do
    new_enabled = !socket.assigns.everypay_enabled
    Settings.update_setting("billing_everypay_enabled", to_string(new_enabled))

    {:noreply,
     socket
     |> assign(:everypay_enabled, new_enabled)
     |> assign(:available_providers, Providers.list_available_providers())
     |> put_flash(
       :info,
       if(new_enabled, do: gettext("EveryPay enabled"), else: gettext("EveryPay disabled"))
     )}
  end

  defp gated_event("save_everypay", params, socket) do
    settings = [
      {"billing_everypay_api_username", params["api_username"] || ""},
      {"billing_everypay_api_secret", params["api_secret"] || ""},
      {"billing_everypay_account_name", params["account_name"] || ""},
      {"billing_everypay_mode", params["mode"] || "test"}
    ]

    Enum.each(settings, fn {key, value} ->
      Settings.update_setting(key, value)
    end)

    {:noreply,
     socket
     |> load_provider_settings()
     |> put_flash(:info, gettext("EveryPay settings saved"))}
  end
end
