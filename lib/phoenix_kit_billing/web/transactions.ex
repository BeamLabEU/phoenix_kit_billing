defmodule PhoenixKitBilling.Web.Transactions do
  @moduledoc """
  Transactions list LiveView for the billing module.

  Provides transaction management interface with filtering, searching, and pagination.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  import PhoenixKitWeb.Components.Core.AdminPageHeader
  alias PhoenixKit.Utils.Routes
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.Pagination
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitWeb.Components.Core.TimeDisplay
  import PhoenixKitBilling.Web.Components.CurrencyDisplay
  import PhoenixKitBilling.Web.Components.TransactionTypeBadge

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Events
  alias PhoenixKitBilling.Transaction

  @default_per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      if connected?(socket) do
        Events.subscribe_transactions()
      end

      socket =
        socket
        |> assign(:page_title, gettext("Transactions"))
        |> assign(:project_title, nil)
        |> assign(:transactions, [])
        |> assign(:total_count, 0)
        |> assign(:loading, true)
        |> assign_filter_defaults()
        |> assign_pagination_defaults()

      {:ok, socket}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> apply_params(params)
      |> load_transactions()

    {:noreply, socket}
  end

  @impl true
  def handle_info({event, _txn}, socket)
      when event in [:transaction_created, :transaction_refunded] do
    {:noreply, load_transactions(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_filter_defaults(socket) do
    socket
    |> assign(:search, "")
    |> assign(:type_filter, "all")
    |> assign(:payment_method_filter, "all")
  end

  defp assign_pagination_defaults(socket) do
    socket
    |> assign(:page, 1)
    |> assign(:per_page, @default_per_page)
    |> assign(:total_pages, 1)
  end

  defp apply_params(socket, params) do
    page = parse_page(params["page"])
    per_page = parse_per_page(params["per_page"])
    search = params["search"] || ""
    type = params["type"] || "all"
    payment_method = params["payment_method"] || "all"

    socket
    |> assign(:page, page)
    |> assign(:per_page, per_page)
    |> assign(:search, search)
    |> assign(:type_filter, type)
    |> assign(:payment_method_filter, payment_method)
  end

  defp parse_page(nil), do: 1
  defp parse_page(page) when is_binary(page), do: max(1, String.to_integer(page))
  defp parse_page(page) when is_integer(page), do: max(1, page)

  defp parse_per_page(nil), do: @default_per_page

  defp parse_per_page(per_page) when is_binary(per_page),
    do: min(100, max(10, String.to_integer(per_page)))

  defp parse_per_page(per_page) when is_integer(per_page), do: min(100, max(10, per_page))

  defp load_transactions(socket) do
    %{
      page: page,
      per_page: per_page,
      search: search,
      type_filter: type,
      payment_method_filter: payment_method
    } = socket.assigns

    opts = [
      page: page,
      per_page: per_page,
      search: search,
      type: if(type == "all", do: nil, else: type),
      payment_method: if(payment_method == "all", do: nil, else: payment_method),
      preload: [:invoice]
    ]

    {transactions, total_count} = Billing.list_transactions_with_count(opts)
    total_pages = ceil(total_count / per_page)

    socket
    |> assign(:transactions, transactions)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, max(1, total_pages))
    |> assign(:loading, false)
  end

  @impl true
  # `replace: true` because the search box is debounced: without it a
  # typed-out query leaves one history entry per pause, and Back walks the
  # search string backwards a few characters at a time instead of leaving
  # the page. Matches the subscriptions list.
  def handle_event("filter", params, socket) do
    new_params = build_url_params(socket.assigns, params)

    {:noreply,
     push_patch(socket,
       to: Routes.path("/admin/billing/transactions?#{new_params}"),
       replace: true
     )}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: Routes.path("/admin/billing/transactions"))}
  end

  @impl true
  def handle_event("view_invoice", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/billing/invoices/#{uuid}"))}
  end

  @impl true
  def handle_event("page_change", %{"page" => page}, socket) do
    new_params = build_url_params(socket.assigns, %{"page" => page})
    {:noreply, push_patch(socket, to: Routes.path("/admin/billing/transactions?#{new_params}"))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(:loading, true) |> load_transactions()}
  end

  defp build_url_params(assigns, new_params) do
    params = %{
      "page" => Map.get(new_params, "page", assigns.page),
      "per_page" => assigns.per_page,
      "search" => Map.get(new_params, "search", assigns.search),
      "type" => Map.get(new_params, "type", assigns.type_filter),
      "payment_method" => Map.get(new_params, "payment_method", assigns.payment_method_filter)
    }

    params
    |> Enum.reject(fn
      {_k, v} when v in ["", "all", nil] -> true
      {"page", 1} -> true
      {"per_page", @default_per_page} -> true
      _ -> false
    end)
    |> URI.encode_query()
  end

  @doc """
  Returns transaction type based on amount sign.
  """
  def transaction_type(%Transaction{} = transaction) do
    Transaction.type(transaction)
  end
end
