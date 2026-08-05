defmodule PhoenixKitBilling.Web.Subscriptions do
  @moduledoc """
  Subscriptions list LiveView for the billing module.

  Displays all subscriptions with filtering and search capabilities.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  import PhoenixKitWeb.Components.Core.UserInfo
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Web.Authz
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitWeb.Components.Core.TimeDisplay
  import PhoenixKitBilling.Web.Components.CurrencyDisplay
  import PhoenixKitBilling.Web.Components.SubscriptionHelpers

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Activity
  alias PhoenixKitBilling.Errors
  alias PhoenixKitBilling.Events

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      if connected?(socket) do
        Events.subscribe_subscriptions()
      end

      # Per phoenix-thinking iron law: no DB queries in mount. Defer the
      # subscription list query to handle_params, which fires once per
      # navigation and where the URL-driven filters live anyway.
      {:ok,
       socket
       |> assign(:page_title, gettext("Subscriptions"))
       |> assign(:project_title, nil)
       |> assign(:status_filter, "all")
       |> assign(:search, "")
       |> assign(:subscriptions, [])
       |> assign(:stats, empty_stats())}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    status = params["status"] || "all"
    search = params["search"] || ""

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:status_filter, status)
      |> assign(:search, search)
      |> load_subscriptions()

    {:noreply, socket}
  end

  defp empty_stats do
    %{total: 0, active: 0, trialing: 0, past_due: 0, cancelled: 0}
  end

  defp load_subscriptions(socket) do
    opts =
      [preload: [:subscription_type, :payment_method, :user]]
      |> add_status_filter(socket.assigns.status_filter)
      |> add_search_filter(socket.assigns.search)

    subscriptions = Billing.list_subscriptions(opts)
    stats = calculate_stats(subscriptions)

    socket
    |> assign(:subscriptions, subscriptions)
    |> assign(:stats, stats)
  end

  defp add_status_filter(opts, "all"), do: opts
  defp add_status_filter(opts, status), do: Keyword.put(opts, :status, status)

  defp add_search_filter(opts, ""), do: opts
  defp add_search_filter(opts, search), do: Keyword.put(opts, :search, search)

  defp calculate_stats(subscriptions) do
    %{
      total: length(subscriptions),
      active: Enum.count(subscriptions, &(&1.status == "active")),
      trialing: Enum.count(subscriptions, &(&1.status == "trialing")),
      past_due: Enum.count(subscriptions, &(&1.status == "past_due")),
      cancelled: Enum.count(subscriptions, &(&1.status == "cancelled"))
    }
  end

  @impl true
  def handle_event("view_subscription", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/billing/subscriptions/#{uuid}"))}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         Routes.path("/admin/billing/subscriptions") <>
           build_query_string(status, socket.assigns.search)
     )}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         Routes.path("/admin/billing/subscriptions") <>
           build_query_string(socket.assigns.status_filter, search)
     )}
  end

  @impl true
  def handle_event("cancel_subscription", params, socket) do
    Authz.authorize(socket, :manage_subscriptions, fn ->
      gated_event("cancel_subscription", params, socket)
    end)
  end

  # PubSub event handlers
  @impl true
  def handle_info({:subscription_created, _subscription}, socket) do
    {:noreply, load_subscriptions(socket)}
  end

  @impl true
  def handle_info({:subscription_cancelled, _subscription}, socket) do
    {:noreply, load_subscriptions(socket)}
  end

  @impl true
  def handle_info({:subscription_renewed, _subscription}, socket) do
    {:noreply, load_subscriptions(socket)}
  end

  @impl true
  def handle_info({:subscription_type_changed, _subscription, _old_type, _new_type}, socket) do
    {:noreply, load_subscriptions(socket)}
  end

  @impl true
  def handle_info({:subscription_status_changed, _subscription, _old_status, _new_status}, socket) do
    {:noreply, load_subscriptions(socket)}
  end

  defp build_query_string(status, search) do
    params =
      []
      |> then(fn p -> if status != "all", do: [{"status", status} | p], else: p end)
      |> then(fn p -> if search != "", do: [{"search", search} | p], else: p end)

    case params do
      [] -> ""
      _ -> "?" <> URI.encode_query(params)
    end
  end

  defp gated_event("cancel_subscription", %{"uuid" => uuid}, socket) do
    subscription = Enum.find(socket.assigns.subscriptions, &(&1.uuid == uuid))

    if subscription do
      case Billing.cancel_subscription(subscription, immediately: false) do
        {:ok, updated} ->
          Activity.log("billing.subscription_cancelled",
            actor_uuid: Activity.actor_uuid(socket),
            actor_role: Activity.actor_role(socket),
            resource_type: "subscription",
            resource_uuid: updated.uuid,
            metadata: %{"status" => updated.status, "immediately" => false}
          )

          {:noreply,
           socket
           |> load_subscriptions()
           |> put_flash(:info, gettext("Subscription will be cancelled at period end"))}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to cancel: %{reason}", reason: Errors.message(reason))
           )}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Subscription not found"))}
    end
  end
end
