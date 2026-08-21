defmodule PhoenixKitBilling.Web.Currencies do
  @moduledoc """
  Currencies management LiveView for the billing module.

  Provides currency configuration interface with CRUD operations
  and bulk import from the BeamLabCountries library.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Web.Authz
  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitBilling.Web.Components.SettingsTabs
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Activity
  alias PhoenixKitBilling.Currency

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:page_title, gettext("Currencies"))
        |> assign(:project_title, project_title)
        |> assign(:currencies, [])
        |> assign(:loading, true)
        |> assign(:show_form, false)
        |> assign(:editing_currency, nil)
        |> assign(:form, nil)
        |> assign(:show_import, false)
        |> assign(:available_currencies, [])
        |> assign(:selected_imports, MapSet.new())

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, load_currencies(socket)}
  end

  defp load_currencies(socket) do
    currencies = Billing.list_currencies(order_by: [asc: :sort_order, asc: :code])

    socket
    |> assign(:currencies, currencies)
    |> assign(:loading, false)
  end

  # --- Toggle / Default / Refresh ---

  @impl true
  def handle_event("toggle_enabled", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_enabled", params, socket)
    end)
  end

  @impl true
  def handle_event("set_default", params, socket) do
    Authz.authorize(socket, :manage_settings, fn -> gated_event("set_default", params, socket) end)
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(:loading, true) |> load_currencies()}
  end

  # --- Currency Form (Add / Edit) ---

  @impl true
  def handle_event("show_add_form", _params, socket) do
    changeset = Currency.changeset(%Currency{}, %{})

    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_currency, nil)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("show_edit_form", %{"uuid" => uuid}, socket) do
    currency = Enum.find(socket.assigns.currencies, &(&1.uuid == uuid))
    changeset = Currency.changeset(currency, %{})

    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_currency, currency)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("close_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_currency, nil)
     |> assign(:form, nil)}
  end

  @impl true
  def handle_event("validate", %{"currency" => params}, socket) do
    changeset =
      (socket.assigns.editing_currency || %Currency{})
      |> Currency.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", params, socket) do
    Authz.authorize(socket, :manage_settings, fn -> gated_event("save", params, socket) end)
  end

  # --- Delete ---

  @impl true
  def handle_event("delete_currency", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("delete_currency", params, socket)
    end)
  end

  # --- Import from BeamLabCountries ---

  @impl true
  def handle_event("show_import", _params, socket) do
    existing_codes =
      socket.assigns.currencies
      |> Enum.map(& &1.code)
      |> MapSet.new()

    # Get company country's currencies to prioritize them (primary + alternative)
    company_country_code = Settings.get_setting("billing_company_country", "")
    priority_currency_codes = get_country_currency_codes(company_country_code)

    available =
      BeamLabCountries.Currencies.all()
      |> Enum.reject(&MapSet.member?(existing_codes, &1.code))
      |> sort_currencies_with_priority(priority_currency_codes)

    {:noreply,
     socket
     |> assign(:show_import, true)
     |> assign(:available_currencies, available)
     |> assign(:selected_imports, MapSet.new())}
  end

  @impl true
  def handle_event("close_import", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_import, false)
     |> assign(:available_currencies, [])
     |> assign(:selected_imports, MapSet.new())}
  end

  @impl true
  def handle_event("toggle_import_selection", %{"code" => code}, socket) do
    selected = socket.assigns.selected_imports

    updated =
      if MapSet.member?(selected, code),
        do: MapSet.delete(selected, code),
        else: MapSet.put(selected, code)

    {:noreply, assign(socket, :selected_imports, updated)}
  end

  @impl true
  def handle_event("select_all_imports", _params, socket) do
    all_codes = MapSet.new(socket.assigns.available_currencies, & &1.code)
    {:noreply, assign(socket, :selected_imports, all_codes)}
  end

  @impl true
  def handle_event("deselect_all_imports", _params, socket) do
    {:noreply, assign(socket, :selected_imports, MapSet.new())}
  end

  @impl true
  def handle_event("import_selected", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("import_selected", params, socket)
    end)
  end

  # --- Helpers ---

  def error_to_string([]), do: ""

  def error_to_string(errors) when is_list(errors) do
    Enum.map_join(errors, ", ", fn
      {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)

      msg when is_binary(msg) ->
        msg
    end)
  end

  # Gets currency codes for a country from BeamLabCountries (primary + alternative)
  defp get_country_currency_codes(country_code)
       when is_binary(country_code) and country_code != "" do
    case BeamLabCountries.get(country_code) do
      %{currency_code: primary, alt_currency: alt} ->
        [primary, alt]
        |> Enum.reject(&(is_nil(&1) or &1 == ""))

      _ ->
        []
    end
  end

  defp get_country_currency_codes(_), do: []

  # Sorts currencies with priority currencies first, then alphabetically
  defp sort_currencies_with_priority(currencies, []) do
    Enum.sort_by(currencies, & &1.code)
  end

  defp sort_currencies_with_priority(currencies, priority_codes) when is_list(priority_codes) do
    priority_set = MapSet.new(priority_codes)
    {priority, rest} = Enum.split_with(currencies, &MapSet.member?(priority_set, &1.code))

    # Sort priority currencies in the order they appear in priority_codes
    sorted_priority =
      Enum.sort_by(priority, fn cur ->
        Enum.find_index(priority_codes, &(&1 == cur.code)) || 999
      end)

    sorted_priority ++ Enum.sort_by(rest, & &1.code)
  end

  defp gated_event("toggle_enabled", %{"uuid" => uuid}, socket) do
    currency = Enum.find(socket.assigns.currencies, &(&1.uuid == uuid))

    case Billing.update_currency(currency, %{enabled: !currency.enabled}) do
      {:ok, updated} ->
        Activity.log("billing.currency_updated",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "currency",
          resource_uuid: updated.uuid,
          metadata: %{"code" => updated.code, "enabled" => updated.enabled}
        )

        {:noreply,
         socket
         |> load_currencies()
         |> put_flash(:info, gettext("Currency updated"))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update currency"))}
    end
  end

  defp gated_event("set_default", %{"uuid" => uuid}, socket) do
    currency = Enum.find(socket.assigns.currencies, &(&1.uuid == uuid))

    case Billing.set_default_currency(currency) do
      {:ok, updated} ->
        Activity.log("billing.currency_set_default",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "currency",
          resource_uuid: updated.uuid,
          metadata: %{"code" => updated.code}
        )

        {:noreply,
         socket
         |> load_currencies()
         |> put_flash(:info, gettext("%{code} set as default currency", code: currency.code))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to set default currency"))}
    end
  end

  defp gated_event("save", %{"currency" => params}, socket) do
    result =
      case socket.assigns.editing_currency do
        nil -> Billing.create_currency(params)
        currency -> Billing.update_currency(currency, params)
      end

    case result do
      {:ok, currency} ->
        action =
          if socket.assigns.editing_currency,
            do: "billing.currency_updated",
            else: "billing.currency_created"

        Activity.log(action,
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "currency",
          resource_uuid: currency.uuid,
          metadata: %{"code" => currency.code}
        )

        message =
          if socket.assigns.editing_currency,
            do: gettext("Currency updated successfully"),
            else: gettext("Currency created successfully")

        {:noreply,
         socket
         |> load_currencies()
         |> assign(:show_form, false)
         |> assign(:editing_currency, nil)
         |> assign(:form, nil)
         |> put_flash(:info, message)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp gated_event("delete_currency", %{"uuid" => uuid}, socket) do
    currency = Enum.find(socket.assigns.currencies, &(&1.uuid == uuid))

    case Billing.delete_currency(currency) do
      {:ok, _currency} ->
        Activity.log("billing.currency_deleted",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "currency",
          resource_uuid: currency.uuid,
          metadata: %{"code" => currency.code}
        )

        {:noreply,
         socket
         |> load_currencies()
         |> put_flash(:info, gettext("%{code} deleted", code: currency.code))}

      {:error, :is_default} ->
        {:noreply, put_flash(socket, :error, gettext("Cannot delete the default currency"))}

      {:error, :currency_in_use} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Cannot delete currency — it is used by existing orders")
         )}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete currency"))}
    end
  end

  defp gated_event("import_selected", _params, socket) do
    selected = socket.assigns.selected_imports

    to_import =
      Enum.filter(socket.assigns.available_currencies, &MapSet.member?(selected, &1.code))

    {ok_count, fail_count} =
      Enum.reduce(to_import, {0, 0}, fn cur, {ok, fail} ->
        attrs = %{
          code: cur.code,
          name: cur.name,
          symbol: cur.symbol_native,
          decimal_places: cur.decimal_digits,
          exchange_rate: "1.0",
          enabled: false
        }

        case Billing.create_currency(attrs) do
          {:ok, _} -> {ok + 1, fail}
          {:error, _} -> {ok, fail + 1}
        end
      end)

    if ok_count > 0 do
      Activity.log("billing.currency_imported",
        actor_uuid: Activity.actor_uuid(socket),
        actor_role: Activity.actor_role(socket),
        resource_type: "currency",
        metadata: %{"imported_count" => ok_count, "failed_count" => fail_count}
      )
    end

    message =
      case {ok_count, fail_count} do
        {ok, 0} -> gettext("%{count} currencies imported", count: ok)
        {0, fail} -> gettext("Import failed for %{count} currencies", count: fail)
        {ok, fail} -> gettext("%{ok} imported, %{fail} failed", ok: ok, fail: fail)
      end

    {:noreply,
     socket
     |> load_currencies()
     |> assign(:show_import, false)
     |> assign(:available_currencies, [])
     |> assign(:selected_imports, MapSet.new())
     |> put_flash(:info, message)}
  end
end
