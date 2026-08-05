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

defmodule PhoenixKitBilling.ProjectExtensionContractTest do
  use ExUnit.Case, async: true

  # The phoenix_kit_projects hub discovers this duck-typed entry; pin the
  # shape (incl. the honest "Customer billing" naming and the shared
  # rate config the projects-side invoice bridge reads).
  test "phoenix_kit_project_extensions/0 declares the Customer billing tab" do
    assert [ext] = PhoenixKitBilling.phoenix_kit_project_extensions()
    assert ext.key == "billing_customer"
    assert ext.name == "Customer billing"
    assert ext.module_key == "billing"
    refute ext.default_enabled
    assert [%{key: "billing", lv: lv}] = ext.tabs
    assert Code.ensure_loaded?(lv)

    config_keys = Enum.map(ext.config_schema, & &1.key)
    assert "billing_profile_uuid" in config_keys
    assert "rate_cents_per_hour" in config_keys
  end
end
