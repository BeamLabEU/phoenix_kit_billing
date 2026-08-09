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

  Off-router-mountable: no `handle_params/3` (the hub's hard
  requirement). Because that rules out the usual "query in
  `handle_params`" split, the reads sit behind a `connected?/1` guard so
  the throwaway static mount does not run them.

  ## Visibility

  The hub authorizes: it only renders this pane for a viewer it has
  already admitted to the project, and an admin has to paste a profile
  UUID into the project's config before anything is linked. Everyone who
  can see the project therefore sees the linked customer's invoice list.
  That is the feature. What this tab must never do is widen that to
  customers the project was NOT linked to — hence the unlinked state
  links out to the billing admin instead of enumerating profiles.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext

  import PhoenixKitBilling.Web.Components.CurrencyDisplay
  import PhoenixKitBilling.Web.Components.InvoiceStatusBadge

  alias PhoenixKitBilling.Paths

  @invoices_limit 15

  @impl true
  def mount(_params, session, socket) do
    maybe_put_locale(session)

    socket =
      assign(socket,
        project_uuid: session["project_uuid"],
        profile: nil,
        invoices: [],
        truncated?: false
      )

    {:ok, if(connected?(socket), do: load(socket, session), else: socket)}
  end

  defp load(socket, session) do
    profile_uuid = get_in(session, ["config", "billing_profile_uuid"])
    profile = profile_uuid && safe(fn -> PhoenixKitBilling.get_billing_profile(profile_uuid) end)

    # One row over the cap tells us whether to say "showing the latest N"
    # without a second count query.
    invoices =
      if profile do
        safe(fn ->
          PhoenixKitBilling.list_user_invoices(profile.user_uuid, %{limit: @invoices_limit + 1})
        end) || []
      else
        []
      end

    assign(socket,
      profile: profile,
      invoices: Enum.take(invoices, @invoices_limit),
      truncated?: length(invoices) > @invoices_limit
    )
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
              {gettext("Customer billing — everything on this customer's profile, not a per-project total.")}
            </p>
          </div>
          <.link navigate={Paths.invoices()} class="btn btn-ghost btn-sm gap-1">
            {gettext("Open in Billing")}
          </.link>
        </div>

        <%= if @invoices == [] do %>
          <div class="card border border-dashed border-base-300 bg-base-100">
            <div class="card-body items-center text-center py-8">
              <p class="text-sm opacity-70">{gettext("No invoices for this customer yet.")}</p>
            </div>
          </div>
        <% else %>
          <div class="overflow-x-auto rounded-lg border border-base-200">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("Invoice")}</th>
                  <th>{gettext("Status")}</th>
                  <th class="text-right">{gettext("Total")}</th>
                  <th>{gettext("Date")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={invoice <- @invoices} class="hover:bg-base-200/40">
                  <td>
                    <.link
                      navigate={Paths.invoice_detail(invoice.uuid)}
                      class="link link-hover font-medium"
                    >
                      {invoice.invoice_number}
                    </.link>
                  </td>
                  <td>
                    <.invoice_status_badge status={invoice.status} />
                  </td>
                  <td class="text-right">
                    <%= if invoice.total do %>
                      <.currency_compact amount={invoice.total} currency={invoice.currency} />
                    <% else %>
                      <span class="opacity-60">—</span>
                    <% end %>
                  </td>
                  <td class="text-xs opacity-60 whitespace-nowrap">
                    {Calendar.strftime(invoice.inserted_at, "%b %-d, %Y")}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <p :if={@truncated?} class="text-xs opacity-60 text-center">
            {gettext("Showing the %{count} most recent invoices.", count: invoices_limit())}
          </p>
        <% end %>
      <% else %>
        <div class="card border border-dashed border-base-300 bg-base-100">
          <div class="card-body py-6 gap-2">
            <p class="text-sm opacity-70 text-center">
              {gettext("No customer linked to this project yet.")}
            </p>
            <p class="text-xs opacity-50 text-center">
              {gettext(
                "Paste a billing profile UUID into this tab's settings in the project's Modules & features panel."
              )}
              {gettext("Find it on the profile page in")}
              <.link navigate={Paths.billing_profiles()} class="link">
                {gettext("Billing › Profiles")}
              </.link>
              .
            </p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp profile_label(profile) do
    profile.company_name || profile.name || gettext("Unnamed profile")
  end

  defp maybe_put_locale(%{"locale" => locale}) when is_binary(locale) and locale != "" do
    Gettext.put_locale(PhoenixKitBilling.Gettext, locale)
  rescue
    _ -> :ok
  end

  defp maybe_put_locale(_), do: :ok

  # A billing hiccup degrades to the empty state — never crash the host.
  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp invoices_limit, do: @invoices_limit
end
