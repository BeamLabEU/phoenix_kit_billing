defmodule PhoenixKitBilling.Web.Components.SettingsTabs do
  @moduledoc """
  The billing settings tab strip, defined once.

  It used to be hand-rolled markup repeated verbatim in four templates —
  `settings`, `provider_settings`, `currencies` and `subscription_types` —
  each hardcoding `tab-active` on its own entry. Adding a fifth page meant
  editing four files, any one of which could drift, and it is why a daisyUI
  class rename needed four edits in this module alone.

  Rendering goes through core's `<.nav_tabs>`, so the strip picks up the
  shared markup, keyboard/ARIA roles and styling rather than restating them.
  """

  use Phoenix.Component

  use Gettext, backend: PhoenixKitBilling.Gettext

  import PhoenixKitWeb.Components.Core.NavTabs, only: [nav_tabs: 1]

  @doc """
  Renders the strip with `active_tab` marked.

  Paths are passed raw — `nav_tabs` runs them through the core route helper,
  which is what applies the install's URL prefix and locale segment.

  The key is `:path`, core's legacy spelling, because these paths are unprefixed:
  `nav_tabs` applies the route helper to `:path` only. `:navigate` and `:patch`
  pass through verbatim, so swapping the key alone would under-prefix every link.
  """
  attr(:active_tab, :string,
    required: true,
    values: ~w(general providers currencies subscription_types)
  )

  attr(:class, :string, default: "mb-6")

  def settings_tabs(assigns) do
    ~H"""
    <.nav_tabs
      active_tab={@active_tab}
      class={@class}
      tabs={[
        %{
          id: "general",
          label: gettext("General"),
          icon: "hero-cog-6-tooth",
          path: "/admin/settings/billing"
        },
        %{
          id: "providers",
          label: gettext("Payment Providers"),
          icon: "hero-credit-card",
          path: "/admin/settings/billing/providers"
        },
        %{
          id: "currencies",
          label: gettext("Currencies"),
          icon: "hero-currency-dollar",
          path: "/admin/billing/currencies"
        },
        %{
          id: "subscription_types",
          label: gettext("Subscription Types"),
          icon: "hero-clipboard-document-list",
          path: "/admin/billing/subscription-types"
        }
      ]}
    />
    """
  end
end
