defmodule PhoenixKitBillingTest do
  use ExUnit.Case, async: true

  alias PhoenixKitBilling, as: Billing

  test "has @phoenix_kit_module attribute" do
    assert Keyword.get(Billing.__info__(:attributes), :phoenix_kit_module) == [true]
  end

  test "module_key/0 returns billing" do
    assert Billing.module_key() == "billing"
  end

  test "module_name/0 returns Billing" do
    assert Billing.module_name() == "Billing"
  end

  # Pins the exact shape the host's :phoenix_kit_css_sources compiler reads.
  # Losing this callback is silent — the compiler guards on
  # function_exported?/3 and simply emits no @source line — and the symptom
  # surfaces far away, as Tailwind purging every billing class from a host
  # build.
  test "css_sources/0 returns the billing app, so hosts scan its templates" do
    assert Billing.css_sources() == [:phoenix_kit_billing]
  end

  test "required_modules/0 returns list" do
    assert is_list(Billing.required_modules())
  end

  test "enabled?/0 returns false without DB" do
    refute Billing.enabled?()
  end

  test "admin_tabs returns non-empty list" do
    tabs = Billing.admin_tabs()
    assert is_list(tabs) and tabs != []
  end

  test "tab IDs namespaced with admin_billing" do
    for tab <- Billing.admin_tabs() do
      assert tab.id |> to_string() |> String.starts_with?("admin_billing")
    end
  end

  test "tab paths use hyphens not underscores" do
    for tab <- Billing.admin_tabs() do
      static = (tab.path || "") |> String.split(":") |> List.first()
      refute String.contains?(static, "_"), "Tab path has underscore: #{tab.path}"
    end
  end

  test "visible tabs have live_view set" do
    for tab <- Billing.admin_tabs(), tab.visible != false do
      assert tab.live_view != nil
    end
  end
end
