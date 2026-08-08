defmodule PhoenixKitBilling.CompatDelegateTest do
  @moduledoc """
  Drift guard for the temporary `PhoenixKit.Modules.Billing.*` compat
  shims under `lib/phoenix_kit_billing/compat/`.

  These modules are thin `defdelegate` layers that keep PhoenixKit core
  working while it still references the old namespace. If a delegated
  function is renamed or removed on the target module, the delegate
  becomes a runtime landmine (a `function_exported?` would pass on the
  shim but the call would crash on dispatch). This test asserts that
  every function the compat shim exports actually exists, at the same
  arity, on the module it delegates to.
  """

  use ExUnit.Case, async: true

  # compat module => target module it delegates to
  @delegate_pairs [
    {PhoenixKit.Modules.Billing, PhoenixKitBilling},
    {PhoenixKit.Modules.Billing.BillingProfile, PhoenixKitBilling.BillingProfile},
    {PhoenixKit.Modules.Billing.IbanData, PhoenixKitBilling.IbanData},
    {PhoenixKit.Modules.Billing.Web.UserBillingProfileForm,
     PhoenixKitBilling.Web.UserBillingProfileForm},
    {PhoenixKit.Modules.Billing.Web.UserBillingProfiles,
     PhoenixKitBilling.Web.UserBillingProfiles}
  ]

  # The zero-arity surface core resolves on a *registered* module with
  # `function_exported?/3` — `PhoenixKit.Module` callbacks plus the two
  # duck-typed hooks. Every one of these fails open: a module that doesn't
  # export it contributes nothing and core moves on without an error, which
  # is how `css_sources/0` went missing on the main module long enough to
  # purge every billing class out of a host's Tailwind build.
  @registered_module_surface ~w(
    enabled? version required_modules module_key module_name route_module
    permission_metadata admin_tabs settings_tabs user_dashboard_tabs
    get_config css_sources notification_types module_stats
  )a

  # Functions injected by `use`/macros on the compat module itself
  # (e.g. Phoenix.LiveView callbacks) that are not delegated and would
  # otherwise be reported as missing on the target. We only want to
  # check the explicitly-delegated public surface.
  @ignored_funcs [
    # Elixir/OTP module internals
    module_info: 0,
    module_info: 1,
    __info__: 1,
    # Phoenix.LiveView injects these on the LiveView compat shims;
    # the genuinely delegated callbacks (mount/render/handle_*) are
    # checked separately because they DO exist on the target.
    __live__: 0,
    __components__: 0,
    __phoenix_verify_routes__: 1
  ]

  for {compat_mod, target_mod} <- @delegate_pairs do
    test "#{inspect(compat_mod)} delegates only to functions exported by #{inspect(target_mod)}" do
      compat_mod = unquote(compat_mod)
      target_mod = unquote(target_mod)

      Code.ensure_loaded!(compat_mod)
      Code.ensure_loaded!(target_mod)

      delegated =
        compat_mod.__info__(:functions)
        |> Enum.reject(fn {name, arity} -> {name, arity} in @ignored_funcs end)

      assert delegated != [], "expected #{inspect(compat_mod)} to export delegated functions"

      missing =
        Enum.reject(delegated, fn {name, arity} ->
          function_exported?(target_mod, name, arity)
        end)

      assert missing == [],
             "#{inspect(compat_mod)} delegates to #{inspect(target_mod)} functions that no " <>
               "longer exist (delegate drift): #{inspect(missing)}"
    end
  end

  # The loop above only guards one direction — that nothing the shim
  # delegates has vanished from the target. Drift the other way is the
  # dangerous one: a callback added to PhoenixKitBilling but not re-exported
  # here leaves the legacy namespace silently short of it.
  test "PhoenixKit.Modules.Billing re-exports the whole registered-module surface" do
    Code.ensure_loaded!(PhoenixKit.Modules.Billing)
    Code.ensure_loaded!(PhoenixKitBilling)

    missing =
      Enum.reject(@registered_module_surface, fn name ->
        # Only require the shim to carry what the target actually implements.
        not function_exported?(PhoenixKitBilling, name, 0) or
          function_exported?(PhoenixKit.Modules.Billing, name, 0)
      end)

    assert missing == [],
           "PhoenixKitBilling implements #{inspect(missing)} but the compat shim does not " <>
             "delegate them — core resolves these with function_exported?/3, so a host " <>
             "registering PhoenixKit.Modules.Billing loses them with no error"
  end
end
