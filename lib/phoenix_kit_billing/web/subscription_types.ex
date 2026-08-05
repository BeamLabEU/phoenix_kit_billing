defmodule PhoenixKitBilling.Web.SubscriptionTypes do
  @moduledoc """
  Subscription types list LiveView for the billing module.

  Displays all subscription types with management actions.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitBilling.Web.Components.CurrencyDisplay
  import PhoenixKitBilling.Web.Components.SubscriptionHelpers

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Activity
  alias PhoenixKitBilling.Errors
  alias PhoenixKitBilling.Web.Authz

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      project_title = Settings.get_project_title()

      socket =
        socket
        |> assign(:page_title, gettext("Subscription Types"))
        |> assign(:project_title, project_title)
        |> load_subscription_types()

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
    {:noreply, socket}
  end

  defp load_subscription_types(socket) do
    types = Billing.list_subscription_types(active_only: false)
    assign(socket, :subscription_types, types)
  end

  @impl true
  def handle_event("toggle_active", params, socket) do
    Authz.authorize(socket, :manage_subscriptions, fn ->
      gated_event("toggle_active", params, socket)
    end)
  end

  @impl true
  def handle_event("delete_subscription_type", params, socket) do
    Authz.authorize(socket, :manage_subscriptions, fn ->
      gated_event("delete_subscription_type", params, socket)
    end)
  end

  defp gated_event("toggle_active", %{"uuid" => uuid}, socket) do
    type = Enum.find(socket.assigns.subscription_types, &(&1.uuid == uuid))

    if type do
      case Billing.update_subscription_type(type, %{active: !type.active}) do
        {:ok, updated} ->
          Activity.log("billing.subscription_type_updated",
            actor_uuid: Activity.actor_uuid(socket),
            actor_role: Activity.actor_role(socket),
            resource_type: "subscription_type",
            resource_uuid: updated.uuid,
            metadata: %{"active" => updated.active}
          )

          {:noreply,
           socket
           |> load_subscription_types()
           |> put_flash(
             :info,
             if(type.active,
               do: gettext("Subscription type deactivated"),
               else: gettext("Subscription type activated")
             )
           )}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to update subscription type: %{reason}",
               reason: Errors.message(reason)
             )
           )}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Subscription type not found"))}
    end
  end

  defp gated_event("delete_subscription_type", %{"uuid" => uuid}, socket) do
    type = Enum.find(socket.assigns.subscription_types, &(&1.uuid == uuid))

    if type do
      case Billing.delete_subscription_type(type) do
        {:ok, _type} ->
          Activity.log("billing.subscription_type_deleted",
            actor_uuid: Activity.actor_uuid(socket),
            actor_role: Activity.actor_role(socket),
            resource_type: "subscription_type",
            resource_uuid: type.uuid,
            metadata: %{}
          )

          {:noreply,
           socket
           |> load_subscription_types()
           |> put_flash(:info, gettext("Subscription type deleted"))}

        {:error, :has_subscriptions} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext(
               "Cannot delete subscription type with active subscriptions. Deactivate it instead."
             )
           )}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to delete subscription type: %{reason}",
               reason: Errors.message(reason)
             )
           )}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Subscription type not found"))}
    end
  end
end
