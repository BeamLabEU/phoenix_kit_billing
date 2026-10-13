defmodule PhoenixKitBilling.UserMenuTabsTest do
  @moduledoc """
  "My Orders" and "Billing Profiles" join the avatar dropdown only beside a
  shop: without a storefront a visitor has no orders of their own, so the
  entries would be noise in every signed-in user's menu.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Dashboard.Tab

  @moduletag :requires_core_user_menu

  test "both user tabs are gated on the shop module" do
    for tab <- PhoenixKitBilling.user_dashboard_tabs() do
      assert tab.metadata[:user_menu] == (&PhoenixKitBilling.user_menu_with_shop?/1),
             "#{inspect(tab.id)} is not gated on the shop"
    end
  end

  test "with no shop module installed, nothing reaches the dropdown" do
    # This suite runs without phoenix_kit_ecommerce, so core knows no "shop" key.
    refute PhoenixKitBilling.user_menu_with_shop?(nil)

    for tab <- PhoenixKitBilling.user_dashboard_tabs() do
      refute Tab.user_menu?(tab, nil)
    end
  end
end
