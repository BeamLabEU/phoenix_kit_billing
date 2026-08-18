defmodule PhoenixKitBilling.Activity do
  @moduledoc """
  Thin wrapper around `PhoenixKit.Activity.log/1` for the billing module.

  Centralizes the `Code.ensure_loaded?/1` guard, the rescue clause, and
  the default metadata (`module: "billing"`, `actor_role`) so every LV
  call site stays consistent and **logging failures never crash the
  caller**.

  ## Where to call this

  Activity logging happens at the **LiveView layer**, on the `{:ok, _}`
  branch of each successful mutation — never inside context functions.
  The LiveView is where the actor is unambiguously known (via
  `socket.assigns[:phoenix_kit_current_scope]`) and where user intent is
  clear ("admin clicked Save"). Context functions stay pure and keep
  stable signatures.

  ## Action strings

  Actions follow `"billing.<resource>_<verb>"`, e.g.
  `"billing.order_created"`, `"billing.invoice_voided"`.

  ## PII safety

  Only ever pass PII-safe metadata: resource uuids, status strings,
  amounts, currency codes, order/invoice numbers, counts. **Never** log
  email, phone, person names, card data, tokens, or free text.
  """

  require Logger

  @module "billing"

  @typedoc """
  Return value of `log/2`. Mirrors `PhoenixKit.Activity.log/1`'s own
  `{:ok, struct()} | {:error, any()}` plus the unavailable sentinel.

  Bare `:ok` used to be part of this type too — two `rescue` clauses
  (`Postgrex.Error`, `DBConnection.OwnershipError`) returned it silently,
  with no log. In practice neither clause is reachable today: core's own
  `PhoenixKit.Activity.log/1` already wraps `repo().insert()` in its own
  catch-all `rescue e -> Logger.warning(...); {:error, e}`, so any
  exception raised inside it — including these two — is caught and
  turned into a normal `{:error, e}` *return value* one level down,
  before it would ever reach this module's own `rescue` (confirmed by
  direct testing: an unowned spawned process calling this function gets
  a logged, returned `{:error, %DBConnection.OwnershipError{}}`, not an
  exception, with or without the two clauses below). Collapsed into one
  clause anyway — dead code with different behavior than its neighbor is
  still worth removing, and it stops relying on a core internal that
  isn't a documented contract to stay this way. `:ok` is no longer part
  of what this function can return, reachable or not.
  """
  @type log_result :: :activity_unavailable | {:ok, struct()} | {:error, any()}

  @doc """
  Logs a billing activity entry via `PhoenixKit.Activity`.

  No-ops (returns `:activity_unavailable`) when core's `PhoenixKit.Activity`
  module isn't loaded, and rescues/catches any failure — logging it and
  returning `{:error, _}` — so the calling LiveView event handler can't
  crash on a logging error, but a failure is still visible to whoever
  looks at either the logs or the return value.

  ## Options

    * `:actor_uuid` — uuid of the acting user (use `actor_uuid/1`)
    * `:actor_role` — role-name string of the actor (use `actor_role/1`)
    * `:mode` — defaults to `"manual"`
    * `:resource_type` — e.g. `"order"`, `"invoice"`, `"currency"`
    * `:resource_uuid` — uuid of the mutated record
    * `:target_uuid` — second-party uuid where applicable
    * `:metadata` — extra PII-safe metadata map (merged over defaults)
  """
  @spec log(String.t(), keyword()) :: log_result()
  def log(action, opts) when is_binary(action) and is_list(opts) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      entry = %{
        action: action,
        module: @module,
        mode: Keyword.get(opts, :mode, "manual"),
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: Keyword.get(opts, :resource_type),
        resource_uuid: Keyword.get(opts, :resource_uuid),
        target_uuid: Keyword.get(opts, :target_uuid),
        metadata: build_metadata(opts)
      }

      PhoenixKit.Activity.log(entry)
    else
      :activity_unavailable
    end
  rescue
    e ->
      Logger.warning("[Billing] Activity logging error: #{Exception.message(e)}")
      {:error, e}
  catch
    :exit, reason ->
      Logger.warning("[Billing] Activity logging exited: #{inspect(reason)}")
      {:error, {:exit, reason}}
  end

  @doc """
  Extracts the acting user's uuid from the LiveView socket assigns.

  Reads `socket.assigns[:phoenix_kit_current_scope]` (the billing
  convention; the production `live_session :phoenix_kit_admin` on_mount
  hook populates it). Returns `nil` for an unauthenticated/absent scope.
  """
  @spec actor_uuid(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> uuid
      _ -> nil
    end
  end

  @doc """
  Extracts the acting user's primary role-name string from the socket's
  scope (first entry of `cached_roles`). Returns `nil` when no role is
  cached. Role names are not PII.
  """
  @spec actor_role(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def actor_role(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{cached_roles: [role | _]} when is_binary(role) -> role
      _ -> nil
    end
  end

  # Merges caller metadata over the default `actor_role` key. Caller
  # values win on collision so a call site can override if needed.
  defp build_metadata(opts) do
    base =
      case Keyword.get(opts, :actor_role) do
        role when is_binary(role) -> %{"actor_role" => role}
        _ -> %{}
      end

    Map.merge(base, Keyword.get(opts, :metadata, %{}))
  end
end
