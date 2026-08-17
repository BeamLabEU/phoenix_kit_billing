defmodule PhoenixKitBilling.Web.ReceiptPrint do
  @moduledoc """
  Printable receipt view - displays receipt in a print-friendly format.

  This page is designed to be printed or saved as PDF directly from the browser.
  Receipts are generated after invoice payment is confirmed.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitWeb.Gettext
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Invoice
  alias PhoenixKitBilling.Web.Authz

  @impl true
  def mount(params, session, socket) do
    # These render a customer's invoice - name, address, line items. The
    # route only requires the base "billing" key, so without this an
    # operator who may only touch provider settings could open any
    # customer's paperwork by URL.
    Authz.authorize_mount(socket, :manage_invoices, fn ->
      do_mount(params, session, socket)
    end)
  end

  defp do_mount(%{"id" => id}, _session, socket) do
    if Billing.enabled?() do
      case Billing.get_invoice(id, preload: [:order, :transactions, :user]) do
        nil ->
          {:ok,
           socket
           |> put_flash(:error, "Invoice not found")
           |> push_navigate(to: Routes.path("/admin/billing/invoices"))}

        %Invoice{receipt_number: nil} = _invoice ->
          {:ok,
           socket
           |> put_flash(:error, "Receipt not yet generated for this invoice")
           |> push_navigate(to: Routes.path("/admin/billing/invoices/#{id}"))}

        invoice ->
          project_title = Settings.get_project_title()
          company_info = Billing.get_company_info()
          transactions = Billing.list_invoice_transactions(invoice.uuid)

          # Calculate receipt status and related data
          receipt_status = Billing.calculate_receipt_status(invoice, transactions)
          {total_refunded, last_refund_date} = calculate_refund_info(transactions)
          last_payment_date = get_last_payment_date(transactions)

          socket =
            socket
            |> assign(:page_title, "Receipt #{invoice.receipt_number}")
            |> assign(:project_title, project_title)
            |> assign(:invoice, invoice)
            |> assign(:transactions, transactions)
            |> assign(:company, company_info)
            |> assign(:receipt_status, receipt_status)
            |> assign(:total_refunded, total_refunded)
            |> assign(:last_refund_date, last_refund_date)
            |> assign(:last_payment_date, last_payment_date)

          {:ok, socket, layout: false}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Billing module is not enabled")
       |> push_navigate(to: Routes.path("/admin"))}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp calculate_refund_info(transactions) do
    refunds =
      transactions
      |> Enum.filter(&Decimal.negative?(&1.amount))
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    total_refunded =
      refunds
      |> Enum.map(& &1.amount)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
      |> Decimal.abs()

    last_refund_date =
      case refunds do
        [first | _] -> first.inserted_at
        [] -> nil
      end

    {total_refunded, last_refund_date}
  end

  defp get_last_payment_date(transactions) do
    transactions
    |> Enum.filter(&Decimal.positive?(&1.amount))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> case do
      [first | _] -> first.inserted_at
      [] -> nil
    end
  end
end
