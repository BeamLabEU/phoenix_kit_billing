defmodule PhoenixKitBilling.Web.CreditNotePrint do
  @moduledoc """
  Printable credit note view - displays refund/credit note in a print-friendly format.

  This page is designed to be printed or saved as PDF directly from the browser.
  Credit notes are generated for refund transactions.

  IMPORTANT: In a credit note, the roles are reversed compared to invoice:
  - The company (seller) is now the PAYER (issuing the refund)
  - The customer is now the PAYEE (receiving the refund)
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
         true <- Transaction.refund?(transaction) do
      mount_credit_note(socket, invoice, transaction)
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
         |> put_flash(:error, "Transaction is not a refund")
         |> push_navigate(to: Routes.path("/admin/billing/invoices/#{invoice_uuid}"))}
    end
  end

  defp mount_credit_note(socket, invoice, transaction) do
    project_title = Settings.get_project_title()
    company_info = Billing.get_company_info()
    credit_note_number = generate_credit_note_number(transaction)

    socket =
      socket
      |> assign(:page_title, "Credit Note #{credit_note_number}")
      |> assign(:project_title, project_title)
      |> assign(:invoice, invoice)
      |> assign(:transaction, transaction)
      |> assign(:credit_note_number, credit_note_number)
      |> assign(:company, company_info)

    {:ok, socket, layout: false}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp generate_credit_note_number(transaction) do
    prefix = Settings.get_setting("billing_credit_note_prefix", "CN")
    # Use transaction number suffix for credit note
    suffix = transaction.transaction_number |> String.replace(~r/^TXN-/, "")
    "#{prefix}-#{suffix}"
  end
end
