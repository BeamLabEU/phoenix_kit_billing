defmodule PhoenixKitBilling.Web.UserOrders do
  @moduledoc """
  Customer-facing orders list.

  Read-only: the current user's own orders, each with its invoices and
  each invoice's payment/refund transactions. No admin actions — creating,
  editing, or voiding anything stays under `/admin/billing/*`.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.LayoutHelpers, only: [dashboard_assigns: 1]
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Accordion
  import PhoenixKitWeb.Components.Core.EmptyState
  import PhoenixKitBilling.Web.Components.CurrencyDisplay
  import PhoenixKitBilling.Web.Components.InvoiceStatusBadge
  import PhoenixKitBilling.Web.Components.OrderStatusBadge

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Transaction

  @impl true
  def mount(_params, _session, socket) do
    user = get_current_user(socket)

    cond do
      not Billing.enabled?() ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Billing module is not enabled"))
         |> push_navigate(to: Routes.path("/dashboard"))}

      is_nil(user) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Please log in to view your orders"))
         |> push_navigate(to: Routes.path("/phoenix_kit/users/log-in"))}

      true ->
        orders = Billing.list_user_orders(user.uuid, %{}, preload: [invoices: :transactions])

        socket =
          socket
          |> assign(:page_title, gettext("My Orders"))
          |> assign(:orders, orders)
          |> assign(:user, user)

        {:ok, socket}
    end
  end

  # Private helpers

  defp get_current_user(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: _} = user} -> user
      _ -> nil
    end
  end
end
