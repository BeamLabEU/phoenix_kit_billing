defmodule PhoenixKitBilling.Web.ProjectBillingLive do
  @moduledoc """
  The **Customer billing** tab for the `phoenix_kit_projects` hub — this
  module's `phoenix_kit_project_extensions/0` contribution.

  HONEST LABELING (the design consult's hard requirement): this tab is
  the linked CUSTOMER's money — every invoice and order on their billing
  profile, across everything they buy — NOT a per-project P&L. The
  per-project money story is the projects-side ledger→invoice bridge,
  which WRITES through this module's public API; this tab is the
  read-only rollup where those drafts (and everything else) appear.

  Config: `billing_profile_uuid` links the customer;
  `rate_cents_per_hour` is read by the projects-side bridge when
  generating drafts from logged effort (stored here so both money
  settings live on one extension). Hub session contract as usual;
  read-only, so `can_write` is unused.
  """

  use Phoenix.LiveView

  alias PhoenixKitBilling.Paths

  @invoices_limit 15

  @impl true
  def mount(_params, session, socket) do
    profile_uuid = get_in(session, ["config", "billing_profile_uuid"])
    profile = profile_uuid && safe(fn -> PhoenixKitBilling.get_billing_profile(profile_uuid) end)

    invoices =
      if profile && profile.user_uuid do
        (safe(fn -> PhoenixKitBilling.list_user_invoices(profile.user_uuid) end) || [])
        |> Enum.take(@invoices_limit)
      else
        []
      end

    candidates =
      if profile, do: [], else: safe(fn -> PhoenixKitBilling.list_billing_profiles() end) || []

    {:ok,
     assign(socket,
       project_uuid: session["project_uuid"],
       profile: profile,
       invoices: invoices,
       candidates: candidates
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <%= if @profile do %>
        <div class="flex items-center gap-3">
          <span class="hero-banknotes w-5 h-5 opacity-70"></span>
          <div class="min-w-0 grow">
            <h3 class="font-semibold truncate">{profile_label(@profile)}</h3>
            <p class="text-xs opacity-60">
              Customer billing — everything on this customer's profile, not a per-project total.
            </p>
          </div>
          <.link navigate={Paths.invoices()} class="btn btn-ghost btn-sm gap-1">
            Open in Billing
          </.link>
        </div>

        <%= if @invoices == [] do %>
          <div class="card border border-dashed border-base-300 bg-base-100">
            <div class="card-body items-center text-center py-8">
              <p class="text-sm opacity-70">No invoices for this customer yet.</p>
            </div>
          </div>
        <% else %>
          <div class="overflow-x-auto rounded-lg border border-base-200">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Invoice</th>
                  <th>Status</th>
                  <th class="text-right">Total</th>
                  <th>Date</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={invoice <- @invoices} class="hover:bg-base-200/40">
                  <td>
                    <.link navigate={Paths.invoice_detail(invoice.uuid)} class="link link-hover font-medium">
                      {invoice.invoice_number}
                    </.link>
                  </td>
                  <td>
                    <span class={["badge badge-sm", status_class(invoice.status)]}>
                      {invoice.status}
                    </span>
                  </td>
                  <td class="text-right font-mono text-sm">
                    {money(invoice.total, invoice.currency)}
                  </td>
                  <td class="text-xs opacity-60 whitespace-nowrap">
                    {Calendar.strftime(invoice.inserted_at, "%b %-d, %Y")}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      <% else %>
        <div class="card border border-dashed border-base-300 bg-base-100">
          <div class="card-body py-6 gap-2">
            <p class="text-sm opacity-70 text-center">
              No customer linked to this project yet.
            </p>
            <p class="text-xs opacity-50 text-center">
              Paste a billing profile UUID into this tab's settings in the
              project's Modules &amp; features panel.
            </p>
            <div :if={@candidates != []} class="mt-2">
              <p class="text-xs font-semibold opacity-60 mb-1">Available profiles:</p>
              <div class="flex flex-col gap-1">
                <div
                  :for={candidate <- @candidates}
                  class="flex items-baseline gap-2 text-xs bg-base-200/60 rounded px-2 py-1"
                >
                  <span class="font-medium shrink-0">{profile_label(candidate)}</span>
                  <code class="opacity-60 truncate">{candidate.uuid}</code>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp profile_label(profile) do
    profile.company_name || profile.name || "Unnamed profile"
  end

  defp status_class("paid"), do: "badge-success"
  defp status_class("sent"), do: "badge-info"
  defp status_class("void"), do: "badge-ghost"
  defp status_class(_), do: "badge-warning"

  defp money(nil, _currency), do: "—"
  defp money(total, currency), do: "#{Decimal.round(total, 2)} #{currency}"

  # A billing hiccup degrades to the empty state — never crash the host.
  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
