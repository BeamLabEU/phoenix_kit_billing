defmodule PhoenixKitBilling.ActivityActorTest do
  @moduledoc """
  Billing reads the actor through core's `PhoenixKitWeb.Actor`, from the
  same socket shape the admin `live_session` builds — the scope first,
  the bare current user as the fallback.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Activity
  alias PhoenixKitBilling.LiveCase

  defp socket(assigns),
    do: %Phoenix.LiveView.Socket{assigns: Map.put(assigns, :__changed__, %{})}

  test "the actor's uuid and first role come from the scope" do
    scope = LiveCase.fake_scope(roles: ["Admin", "Owner"])
    socket = socket(%{phoenix_kit_current_scope: scope})

    assert Activity.actor_uuid(socket) == scope.user.uuid
    assert Activity.actor_role(socket) == "Admin"
  end

  test "without a scope the bare current user is the actor, with no role" do
    uuid = Ecto.UUID.generate()
    socket = socket(%{phoenix_kit_current_user: %{uuid: uuid}})

    assert Activity.actor_uuid(socket) == uuid
    assert Activity.actor_role(socket) == nil
  end

  test "nobody signed in is no actor" do
    assert Activity.actor_uuid(socket(%{})) == nil
    assert Activity.actor_role(socket(%{})) == nil
  end
end
