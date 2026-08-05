defmodule PhoenixKitBilling.Web.PaymentConfirmationPrint do
  @moduledoc """
  Printable payment confirmation view - displays individual payment in a print-friendly format.

  This page is designed to be printed or saved as PDF directly from the browser.
  Payment confirmations are generated for individual payment transactions.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitWeb.Gettext
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Transaction
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

  defp do_mount(%{"id" => invoice_uuid, "transaction_uuid" => transaction_uuid}, _session, socket) do
    with true <- Billing.enabled?(),
         %{} = invoice <- Billing.get_invoice(invoice_uuid, preload: [:order]),
         %Transaction{} = transaction <- Billing.get_transaction(transaction_uuid),
         true <- Transaction.payment?(transaction) do
      mount_payment_confirmation(socket, invoice, transaction)
    else
      false ->
        {:ok,
         socket
         |> put_flash(:error, "Billing module is not enabled")
         |> push_navigate(to: Routes.path("/admin"))}

      nil ->
        error_msg =
          if Billing.get_invoice(invoice_uuid) == nil,
            do: "Invoice not found",
            else: "Transaction not found"

        redirect_path =
          if Billing.get_invoice(invoice_uuid) == nil,
            do: Routes.path("/admin/billing/invoices"),
            else: Routes.path("/admin/billing/invoices/#{invoice_uuid}")

        {:ok,
         socket
         |> put_flash(:error, error_msg)
         |> push_navigate(to: redirect_path)}

      %Transaction{} ->
        {:ok,
         socket
         |> put_flash(:error, "Transaction is not a payment")
         |> push_navigate(to: Routes.path("/admin/billing/invoices/#{invoice_uuid}"))}
    end
  end

  defp mount_payment_confirmation(socket, invoice, transaction) do
    project_title = Settings.get_project_title()
    company_info = Billing.get_company_info()
    confirmation_number = generate_confirmation_number(transaction)
    all_transactions = Billing.list_invoice_transactions(invoice.uuid)
    payment_context = calculate_payment_context(invoice, transaction, all_transactions)

    socket =
      socket
      |> assign(:page_title, "Payment Confirmation #{confirmation_number}")
      |> assign(:project_title, project_title)
      |> assign(:invoice, invoice)
      |> assign(:transaction, transaction)
      |> assign(:confirmation_number, confirmation_number)
      |> assign(:company, company_info)
      |> assign(:payment_context, payment_context)

    {:ok, socket, layout: false}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp generate_confirmation_number(transaction) do
    prefix = Settings.get_setting("billing_payment_confirmation_prefix", "PMT")
    suffix = transaction.transaction_number |> String.replace(~r/^TXN-/, "")
    "#{prefix}-#{suffix}"
  end

  defp calculate_payment_context(invoice, transaction, all_transactions) do
    # Payments up to and including this transaction
    sorted_payments =
      all_transactions
      |> Enum.filter(&Decimal.positive?(&1.amount))
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

    # Find position of current payment
    payment_index =
      Enum.find_index(sorted_payments, fn t -> t.uuid == transaction.uuid end) || 0

    # Total paid up to and including this payment
    payments_up_to_now = Enum.take(sorted_payments, payment_index + 1)

    total_paid_so_far =
      payments_up_to_now
      |> Enum.map(& &1.amount)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    remaining_balance = Decimal.sub(invoice.total, total_paid_so_far)

    is_final_payment = Decimal.lte?(remaining_balance, Decimal.new(0))

    %{
      payment_number: payment_index + 1,
      total_payments: length(sorted_payments),
      total_paid_so_far: total_paid_so_far,
      remaining_balance: Decimal.max(remaining_balance, Decimal.new(0)),
      is_final_payment: is_final_payment
    }
  end
end
