defmodule PhoenixKitBilling.Web.UserBillingProfileForm do
  @moduledoc """
  User billing profile form LiveView for creating and editing own billing profiles.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitBilling.Gettext
  alias PhoenixKit.Utils.Routes
  import PhoenixKitWeb.LayoutHelpers, only: [dashboard_assigns: 1]
  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitWeb.Components.Core.Icon
  import PhoenixKitWeb.Components.Core.FormFieldError

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
          |> load_profile(params["id"])

        {:ok, socket}
    end
  end

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

        <form phx-change="validate" phx-submit="save" class="space-y-6">
          <%!-- Profile Type Selection --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-user-circle" class="w-5 h-5" /> {gettext("Profile Type")}
              </h2>

              <div class="flex gap-4 mt-2">
                <label class="flex items-center gap-2 cursor-pointer">
                  <input
                    type="radio"
                    name="profile_type"
                    value="individual"
                    class="radio radio-primary"
                    checked={@profile_type == "individual"}
                    phx-click="change_type"
                    phx-value-type="individual"
                  />
                  <span class="fieldset-legend">{gettext("Individual")}</span>
                </label>
                <label class="flex items-center gap-2 cursor-pointer">
                  <input
                    type="radio"
                    name="profile_type"
                    value="company"
                    class="radio radio-primary"
                    checked={@profile_type == "company"}
                    phx-click="change_type"
                    phx-value-type="company"
                  />
                  <span class="fieldset-legend">{gettext("Company")}</span>
                </label>
              </div>
            </div>
          </div>

          <%!-- Individual Fields --%>
          <%= if @profile_type == "individual" do %>
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <h2 class="card-title text-lg">
                  <.icon name="hero-user" class="w-5 h-5" /> {gettext("Personal Information")}
                </h2>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div class="fieldset">
                    <label class="label">
                      <span class="fieldset-legend">{gettext("First Name *")}</span>
                    </label>
                    <input
                      type="text"
                      name="billing_profile[first_name]"
                      value={@form[:first_name].value}
                      class="input"
                      placeholder={gettext("John")}
                    />
                    <.error :for={msg <- @form[:first_name].errors |> Enum.map(&elem(&1, 0))}>
                      {msg}
                    </.error>
                  </div>

                  <div class="fieldset">
                    <label class="label">
                      <span class="fieldset-legend">{gettext("Last Name *")}</span>
                    </label>
                    <input
                      type="text"
                      name="billing_profile[last_name]"
                      value={@form[:last_name].value}
                      class="input"
                      placeholder={gettext("Doe")}
                    />
                    <.error :for={msg <- @form[:last_name].errors |> Enum.map(&elem(&1, 0))}>
                      {msg}
                    </.error>
                  </div>
                </div>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
                  <div class="fieldset">
                    <label class="label">
                      <span class="fieldset-legend">{gettext("Email")}</span>
                    </label>
                    <input
                      type="email"
                      name="billing_profile[email]"
                      value={@form[:email].value}
                      class="input"
                      placeholder="john@example.com"
                    />
                  </div>

                  <div class="fieldset">
                    <label class="label">
                      <span class="fieldset-legend">{gettext("Phone")}</span>
                    </label>
                    <input
                      type="tel"
                      name="billing_profile[phone]"
                      value={@form[:phone].value}
                      class="input"
                      placeholder="+372 5555 5555"
                    />
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Company Fields --%>
          <%= if @profile_type == "company" do %>
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body">
                <h2 class="card-title text-lg">
                  <.icon name="hero-building-office" class="w-5 h-5" /> {gettext("Company Information")}
                </h2>

                <div class="fieldset">
                  <label class="label">
                    <span class="fieldset-legend">{gettext("Company Name *")}</span>
                  </label>
                  <input
                    type="text"
                    name="billing_profile[company_name]"
                    value={@form[:company_name].value}
                    class="input"
                    placeholder={gettext("Acme Corp OÜ")}
                  />
                  <.error :for={msg <- @form[:company_name].errors |> Enum.map(&elem(&1, 0))}>
                    {msg}
                  </.error>
                </div>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-4">
                  <div class="fieldset">
                    <label class="label">
                      <span class="fieldset-legend">{gettext("VAT Number")}</span>
                    </label>
                    <input
                      type="text"
                      name="billing_profile[company_vat_number]"
                      value={@form[:company_vat_number].value}
                      class="input font-mono"
                      placeholder="EE123456789"
                    />
                    <label class="label">
                      <span class="fieldset-label">{gettext("EU VAT format: Country code + number")}</span>
                    </label>
                  </div>

                  <div class="fieldset">
                    <label class="label">
                      <span class="fieldset-legend">{gettext("Registration Number")}</span>
                    </label>
                    <input
                      type="text"
                      name="billing_profile[company_registration_number]"
                      value={@form[:company_registration_number].value}
                      class="input font-mono"
                      placeholder="12345678"
                    />
                  </div>
                </div>

                <div class="fieldset mt-4">
                  <label class="label">
                    <span class="fieldset-legend">{gettext("Legal Address")}</span>
                  </label>
                  <textarea
                    name="billing_profile[company_legal_address]"
                    class="textarea"
                    rows="2"
                    placeholder={gettext("Registered legal address")}
                  >{@form[:company_legal_address].value}</textarea>
                </div>

                <div class="divider">{gettext("Contact")}</div>

                <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                  <div class="fieldset">
                    <label class="label">
                      <span class="fieldset-legend">{gettext("Contact Email")}</span>
                    </label>
                    <input
                      type="email"
                      name="billing_profile[email]"
                      value={@form[:email].value}
                      class="input"
                      placeholder="billing@company.com"
                    />
                  </div>

                  <div class="fieldset">
                    <label class="label">
                      <span class="fieldset-legend">{gettext("Phone")}</span>
                    </label>
                    <input
                      type="tel"
                      name="billing_profile[phone]"
                      value={@form[:phone].value}
                      class="input"
                      placeholder="+372 5555 5555"
                    />
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Billing Address (Country FIRST) --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-map-pin" class="w-5 h-5" /> {gettext("Billing Address")}
              </h2>

              <%!-- Country first --%>
              <div class="fieldset">
                <label class="label">
                  <span class="fieldset-legend">{gettext("Country *")}</span>
                </label>
                <select name="billing_profile[country]" class="select">
                  <option value="">{gettext("Select country...")}</option>
                  <%= for {name, code} <- @countries do %>
                    <option value={code} selected={@form[:country].value == code}>
                      {name}
                    </option>
                  <% end %>
                </select>
              </div>

              <div class="fieldset mt-4">
                <label class="label">
                  <span class="fieldset-legend">{gettext("Address Line 1")}</span>
                </label>
                <input
                  type="text"
                  name="billing_profile[address_line1]"
                  value={@form[:address_line1].value}
                  class="input"
                  placeholder={gettext("Street address")}
                />
              </div>

              <div class="fieldset">
                <label class="label">
                  <span class="fieldset-legend">{gettext("Address Line 2")}</span>
                </label>
                <input
                  type="text"
                  name="billing_profile[address_line2]"
                  value={@form[:address_line2].value}
                  class="input"
                  placeholder={gettext("Apartment, suite, etc.")}
                />
              </div>

              <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 mt-4">
                <div class="fieldset">
                  <label class="label">
                    <span class="fieldset-legend">{gettext("City")}</span>
                  </label>
                  <input
                    type="text"
                    name="billing_profile[city]"
                    value={@form[:city].value}
                    class="input"
                    placeholder={gettext("Tallinn")}
                  />
                </div>

                <div class="fieldset">
                  <label class="label">
                    <span class="fieldset-legend">{@subdivision_label}</span>
                  </label>
                  <input
                    type="text"
                    name="billing_profile[state]"
                    value={@form[:state].value}
                    class="input"
                    placeholder={gettext("Harju")}
                  />
                </div>

                <div class="fieldset">
                  <label class="label">
                    <span class="fieldset-legend">{gettext("Postal Code")}</span>
                  </label>
                  <input
                    type="text"
                    name="billing_profile[postal_code]"
                    value={@form[:postal_code].value}
                    class="input"
                    placeholder="10115"
                  />
                </div>
              </div>
            </div>
          </div>

          <%!-- Options --%>
          <div class="card bg-base-100 shadow-lg">
            <div class="card-body">
              <h2 class="card-title text-lg">
                <.icon name="hero-cog-6-tooth" class="w-5 h-5" /> {gettext("Options")}
              </h2>

              <div class="fieldset">
                <.checkbox field={@form[:is_default]} label={gettext("Set as default profile")}>
                  <:description>
                    {gettext("This profile will be used by default for new orders")}
                  </:description>
                </.checkbox>
              </div>

              <div class="fieldset mt-4">
                <label class="label">
                  <span class="fieldset-legend">{gettext("Profile Name (Optional)")}</span>
                </label>
                <input
                  type="text"
                  name="billing_profile[name]"
                  value={@form[:name].value}
                  class="input"
                  placeholder={gettext("e.g., Home Address, Work")}
                />
                <label class="label">
                  <span class="fieldset-label">{gettext("Custom name to identify this profile")}</span>
                </label>
              </div>
            </div>
          </div>

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
        </form>
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
