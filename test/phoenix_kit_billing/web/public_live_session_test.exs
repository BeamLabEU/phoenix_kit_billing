defmodule PhoenixKitBilling.Web.PublicLiveSessionTest do
  @moduledoc """
  The public payment page's live_session (`Web.Routes.generate/1`) carries the
  host's CSP nonce into the connected LiveView through core's `PhoenixKitWeb.CSP`
  when core has it, and is unchanged on a core without it.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Web.Routes

  @scope_mount {PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}

  test "core's CSP session and on_mount are used when core has them, and only then" do
    opts = Routes.public_session_opts([MyHook])

    if Code.ensure_loaded?(PhoenixKitWeb.CSP) and
         function_exported?(PhoenixKitWeb.CSP, :live_session, 1) do
      assert opts[:session] == {PhoenixKitWeb.CSP, :live_session, []}
      assert opts[:on_mount] == [PhoenixKitWeb.CSP, MyHook, @scope_mount]
    else
      assert opts == [on_mount: [MyHook, @scope_mount]]
    end
  end

  test "the generated routes use those options" do
    quoted = Routes.generate("/") |> Macro.to_string()

    assert quoted =~ "live_session(:phoenix_kit_billing_public"
    assert quoted =~ "phoenix_kit_mount_current_scope"
  end
end
