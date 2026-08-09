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
    # Compared against the real OTP app name rather than a repeated literal:
    # the compiler resolves the atom against the host's deps by app name, so
    # the two must be the same value, and a package rename must fail here
    # instead of quietly emitting an @source for a directory that isn't there.
    assert Billing.css_sources() == [Application.get_application(Billing)]
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

  # The hub renders contributed tabs with `live_render`, so the LV must be
  # mountable off-router. Exporting `handle_params/3` makes LiveView demand
  # a router match and the embed raises — a failure only visible from the
  # projects side, which does not depend on this package.
  test "the contributed tab LV is off-router-mountable" do
    [%{tabs: [%{lv: lv}]}] = PhoenixKitBilling.phoenix_kit_project_extensions()
    Code.ensure_loaded!(lv)

    refute function_exported?(lv, :handle_params, 3)
    assert function_exported?(lv, :mount, 3)
  end

  # `config_schema` types are validated by the hub's normalizer, which
  # DROPS fields whose type isn't in its whitelist — a typo'd type
  # silently loses the field from the settings form.
  test "config_schema uses types the hub normalizer accepts" do
    [ext] = PhoenixKitBilling.phoenix_kit_project_extensions()
    hub_types = [:string, :text, :number, :boolean, :select]

    for field <- ext.config_schema do
      assert field.type in hub_types, "unsupported config_schema type: #{inspect(field.type)}"
      assert is_binary(field.label) and field.label != ""
    end
  end
end
