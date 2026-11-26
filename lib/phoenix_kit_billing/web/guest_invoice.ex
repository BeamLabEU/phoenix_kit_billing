defmodule PhoenixKitBilling.Web.GuestInvoice do
  @moduledoc """
  The public payment page of an invoice (`/billing/pay/:token`).

  No account and no session: the signed token from
  `PhoenixKitBilling.InvoiceLinks` is the credential, so a guest payer (an invoice
  with a billing email and no user) can see what they owe and pay it. While the
  invoice can be paid, every available provider gets a button that opens its
  hosted checkout (`PhoenixKitBilling.create_checkout_session/3`) and comes back
  here. The page follows its invoice over PubSub (`Events.subscribe_invoice/1`),
  so the payment shows up as soon as the provider's webhook lands.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext

  import PhoenixKitBilling.Web.Components.CurrencyDisplay
  import PhoenixKitBilling.Web.Components.InvoiceStatusBadge

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.{Errors, Events, Invoice, InvoiceLinks, Paths, Providers}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, invoice: nil, token: nil, checkout_done: false, paying: nil)}
  end

  @impl true
  def handle_params(%{"token" => token} = params, uri, socket) do
    invoice = InvoiceLinks.invoice_from_token(token)

    if invoice && connected?(socket) && is_nil(socket.assigns.invoice) do
      Events.subscribe_invoice(invoice.uuid)
    end

    {:noreply,
     assign(socket,
       invoice: invoice,
       token: token,
       checkout_done: params["checkout"] == "done",
       url_path: URI.parse(uri).path,
       page_title: page_title(invoice),
       providers: if(invoice, do: Providers.list_available_providers(), else: [])
     )}
  end

  @impl true
  def handle_event("pay", %{"provider" => name}, socket) do
    # Re-read through the token: the invoice may have been paid or voided since.
    with %Invoice{} = invoice <- InvoiceLinks.invoice_from_token(socket.assigns.token),
         provider when not is_nil(provider) <- find_provider(name),
         true <- payable?(invoice) || :not_payable do
      back = Routes.base_url() <> Paths.invoice_pay(socket.assigns.token)

      case Billing.create_checkout_session(invoice, provider,
             success_url: back <> "?checkout=done",
             cancel_url: back
           ) do
        {:ok, url} ->
          {:noreply, socket |> assign(:paying, name) |> redirect(external: url)}

        {:error, reason} ->
          {:noreply,
           socket |> assign(:invoice, invoice) |> put_flash(:error, Errors.message(reason))}
      end
    else
      nil ->
        {:noreply, put_flash(socket, :error, gettext("This payment method is not available."))}

      _ ->
        {:noreply,
         socket
         |> assign(:invoice, InvoiceLinks.invoice_from_token(socket.assigns.token))
         |> put_flash(:error, Errors.message(:invoice_not_payable))}
    end
  end

  @impl true
  def handle_info({event, %{uuid: _} = _record}, %{assigns: %{invoice: %Invoice{}}} = socket)
      when is_atom(event) do
    # Any event on this invoice: show it as it is now.
    {:noreply, assign(socket, :invoice, InvoiceLinks.invoice_from_token(socket.assigns.token))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp find_provider(name) do
    Enum.find(Providers.list_available_providers(), &(Atom.to_string(&1) == name))
  end

  defp payable?(invoice),
    do: Invoice.payable?(invoice) and Decimal.positive?(Invoice.remaining_amount(invoice))

  defp page_title(nil), do: gettext("Invoice")

  defp page_title(invoice),
    do: gettext("Invoice %{number}", number: invoice.invoice_number)

  defp provider_name(provider), do: Providers.provider_info(provider).name

  defp payer(%Invoice{user: %{email: email}}) when is_binary(email), do: email
  defp payer(%Invoice{billing_details: details}), do: Invoice.payer_name(details)

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      socket={@socket}
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      current_path={assigns[:url_path] || "/"}
    >
      <div class="max-w-2xl mx-auto px-4 py-10" id="billing-guest-invoice">
        <div :if={is_nil(@invoice)} class="alert alert-warning">
          {gettext("This link is invalid or has expired.")}
        </div>

        <div :if={@invoice} class="card bg-base-100 shadow-lg">
          <div class="card-body gap-4">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <h1 class="card-title text-2xl">
                {gettext("Invoice %{number}", number: @invoice.invoice_number)}
              </h1>
              <.invoice_status_badge status={@invoice.status} size={:md} />
            </div>

            <div :if={payer(@invoice)} class="text-base-content/70">{payer(@invoice)}</div>

            <div :if={@invoice.due_date} class="text-sm text-base-content/70">
              {gettext("Due date:")} {@invoice.due_date}
            </div>

            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Item")}</th>
                  <th class="text-right">{gettext("Qty")}</th>
                  <th class="text-right">{gettext("Total")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={item <- @invoice.line_items || []}>
                  <td>{item["name"]}</td>
                  <td class="text-right">{item["quantity"]}</td>
                  <td class="text-right">
                    <.currency_compact amount={item["total"]} currency={@invoice.currency} />
                  </td>
                </tr>
              </tbody>
            </table>

            <div class="flex flex-col items-end gap-1">
              <div>
                {gettext("Total")}:
                <span class="font-semibold">
                  <.currency_compact amount={@invoice.total} currency={@invoice.currency} />
                </span>
              </div>
              <div :if={Decimal.positive?(@invoice.paid_amount || Decimal.new(0))}>
                {gettext("Paid")}:
                <.currency_compact amount={@invoice.paid_amount} currency={@invoice.currency} />
              </div>
              <div :if={payable?(@invoice)} class="text-lg" id="billing-guest-invoice-due">
                {gettext("Amount due")}:
                <span class="font-bold">
                  <.currency_compact
                    amount={Invoice.remaining_amount(@invoice)}
                    currency={@invoice.currency}
                  />
                </span>
              </div>
            </div>

            <div :if={@invoice.status == "paid"} class="alert alert-success">
              {gettext("This invoice is paid. Thank you!")}
            </div>

            <div :if={@invoice.status == "void"} class="alert alert-warning">
              {gettext("This invoice was cancelled and cannot be paid.")}
            </div>

            <div :if={@checkout_done and payable?(@invoice)} class="alert alert-info">
              {gettext("Thank you! Your payment is being confirmed; this page updates when it is.")}
            </div>

            <div :if={payable?(@invoice) and not @checkout_done} class="card-actions justify-end">
              <p :if={@providers == []} class="text-sm text-base-content/70">
                {gettext("Online payment is not available. Please use the payment details on the invoice.")}
              </p>
              <button
                :for={provider <- @providers}
                type="button"
                class="btn btn-primary"
                phx-click="pay"
                phx-value-provider={provider}
                disabled={@paying != nil}
              >
                {gettext("Pay with %{provider}", provider: provider_name(provider))}
              </button>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
