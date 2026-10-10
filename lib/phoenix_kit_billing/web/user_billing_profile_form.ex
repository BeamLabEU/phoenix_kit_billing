defmodule PhoenixKitBilling.Web.UserBillingProfileForm do
  @moduledoc """
  User billing profile form LiveView for creating and editing own billing profiles.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  alias PhoenixKit.Utils.Routes
  import PhoenixKitWeb.LayoutHelpers, only: [dashboard_assigns: 1]
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitBilling.Web.Components.BillingProfileFields, only: [billing_profile_fields: 1]

  alias PhoenixKit.Utils.CountryData
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Activity
  alias PhoenixKitBilling.BillingProfile

  @impl true
  def mount(params, _session, socket) do
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
         |> put_flash(:error, gettext("Please log in to manage billing profiles"))
         |> push_navigate(to: Routes.path("/phoenix_kit/users/log-in"))}

      true ->
        countries = CountryData.countries_for_select()
        return_to = params["return_to"]

        socket =
          socket
          |> assign(:user, user)
          |> assign(:countries, countries)
          |> assign(:profile_type, "individual")
          |> assign(:subdivision_label, gettext("Region"))
          |> assign(:return_to, return_to)
          |> load_profile(profile_param(params))

        {:ok, socket}
    end
  end

  # Core mounts the edit page as `/dashboard/billing-profiles/:uuid/edit`
  # (`PhoenixKitWeb.Integration`), so the profile arrives as "uuid". Reading
  # only "id" left every edit link on the "New Billing Profile" form, and
  # saving it created a duplicate. "id" stays accepted for hosts that route
  # the page themselves with `:id`.
  defp profile_param(params), do: params["uuid"] || params["id"]

  defp load_profile(socket, nil) do
    # New profile
    changeset = Billing.change_billing_profile(%BillingProfile{type: "individual"})

    socket
    |> assign(:page_title, gettext("New Billing Profile"))
    |> assign(:profile, nil)
    |> assign(:form, to_form(changeset))
  end

  defp load_profile(socket, id) do
    case Billing.get_billing_profile(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Billing profile not found"))
        |> push_navigate(to: Routes.path("/dashboard/billing-profiles"))

      profile ->
        # Verify ownership
        if profile.user_uuid != socket.assigns.user.uuid do
          socket
          |> put_flash(:error, gettext("Access denied"))
          |> push_navigate(to: Routes.path("/dashboard/billing-profiles"))
        else
          changeset = Billing.change_billing_profile(profile)

          socket
          |> assign(:page_title, gettext("Edit Billing Profile"))
          |> assign(:profile, profile)
          |> assign(:form, to_form(changeset))
          |> assign(:profile_type, profile.type)
          |> assign(:subdivision_label, CountryData.get_subdivision_label(profile.country))
        end
    end
  end

  @impl true
  def handle_event("change_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :profile_type, type)}
  end

  @impl true
  def handle_event("validate", %{"billing_profile" => params}, socket) do
    changeset =
      (socket.assigns.profile || %BillingProfile{})
      |> Billing.change_billing_profile(params)
      |> Map.put(:action, :validate)

    # Update subdivision label when country changes
    subdivision_label = CountryData.get_subdivision_label(params["country"])

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:subdivision_label, subdivision_label)}
  end

  @impl true
  def handle_event("save", %{"billing_profile" => params}, socket) do
    params =
      params
      |> Map.put("user_uuid", socket.assigns.user.uuid)
      |> Map.put("type", socket.assigns.profile_type)

    save_profile(socket, params)
  end

  defp save_profile(socket, params) do
    result =
      if socket.assigns.profile do
        Billing.update_billing_profile(socket.assigns.profile, params)
      else
        Billing.create_billing_profile(socket.assigns.user.uuid, params)
      end

    case result do
      {:ok, profile} ->
        action =
          if socket.assigns.profile,
            do: "billing.billing_profile_updated",
            else: "billing.billing_profile_created"

        Activity.log(action,
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "billing_profile",
          resource_uuid: profile.uuid,
          metadata: %{
            "type" => profile.type,
            "country" => profile.country,
            "is_default" => profile.is_default
          }
        )

        message =
          if socket.assigns.profile,
            do: gettext("Billing profile updated successfully"),
            else: gettext("Billing profile created successfully")

        redirect_path = socket.assigns.return_to || Routes.path("/dashboard/billing-profiles")

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: redirect_path)}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Layouts.dashboard {dashboard_assigns(assigns)}>
      <div class="p-6 max-w-3xl mx-auto">
        <%!-- Header --%>
        <div class="flex items-center gap-4 mb-8">
          <.link
            navigate={@return_to || Routes.path("/dashboard/billing-profiles")}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-arrow-left" class="w-5 h-5" />
          </.link>
          <div>
            <h1 class="text-2xl font-bold">{@page_title}</h1>
            <p class="text-base-content/60 text-sm">
              <%= if @profile do %>
                {gettext("Update your billing information")}
              <% else %>
                {gettext("Create a new billing profile for orders")}
              <% end %>
            </p>
          </div>
        </div>

        <.form
          for={@form}
          id="user-billing-profile-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-6"
        >
          <.billing_profile_fields
            form={@form}
            type={@profile_type}
            countries={@countries}
            subdivision_label={@subdivision_label}
          />

          <%!-- Actions --%>
          <div class="flex justify-end gap-4">
            <.link
              navigate={@return_to || Routes.path("/dashboard/billing-profiles")}
              class="btn btn-ghost"
            >
              {gettext("Cancel")}
            </.link>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-check" class="w-5 h-5 mr-2" />
              {if @profile, do: gettext("Save Changes"), else: gettext("Create Profile")}
            </button>
          </div>
        </.form>
      </div>
    </PhoenixKitWeb.Layouts.dashboard>
    """
  end

  # Private helpers

  defp get_current_user(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: _} = user} -> user
      _ -> nil
    end
  end
end
