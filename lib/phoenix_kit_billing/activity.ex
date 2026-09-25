defmodule PhoenixKitBilling.Activity do
  @moduledoc """
  Thin wrapper around `PhoenixKit.Activity.log/3` for the billing module:
  the module key and the `actor_role` metadata, so every LV call site
  stays consistent. Logging failures never crash the caller — core
  guarantees that.

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

  @module "billing"

  @doc """
  Logs a billing activity entry through `PhoenixKit.Activity.log/3`, which
  never raises — a failed insert, a raise or a dead pool comes back as
  `{:error, _}` and is logged there.

  ## Options

    * `:actor_uuid` — uuid of the acting user (use `actor_uuid/1`)
    * `:actor_role` — role-name string of the actor (use `actor_role/1`),
      stored in the metadata as `"actor_role"`
    * `:mode` — defaults to `"manual"`
    * `:resource_type` — e.g. `"order"`, `"invoice"`, `"currency"`
    * `:resource_uuid` — uuid of the mutated record
    * `:target_uuid` — second-party uuid where applicable
    * `:metadata` — extra PII-safe metadata map (merged over defaults)
  """
  @spec log(String.t(), keyword()) :: {:ok, struct()} | {:error, any()}
  def log(action, opts) when is_binary(action) and is_list(opts) do
    PhoenixKit.Activity.log(@module, action, Keyword.put(opts, :metadata, build_metadata(opts)))
  end

  @doc "The acting user's uuid — see `PhoenixKitWeb.Actor.uuid/1`."
  @spec actor_uuid(Phoenix.LiveView.Socket.t() | map() | nil) :: String.t() | nil
  defdelegate actor_uuid(source), to: PhoenixKitWeb.Actor, as: :uuid

  @doc """
  The acting user's primary role name (not PII), or `nil` — see
  `PhoenixKitWeb.Actor.role/1`.
  """
  @spec actor_role(Phoenix.LiveView.Socket.t() | map() | nil) :: String.t() | nil
  defdelegate actor_role(source), to: PhoenixKitWeb.Actor, as: :role

  # Merges caller metadata over the default `actor_role` key. Caller
  # values win on collision so a call site can override if needed.
  defp build_metadata(opts) do
    base =
      case Keyword.get(opts, :actor_role) do
        role when is_binary(role) -> %{"actor_role" => role}
        _ -> %{}
      end

    Map.merge(base, Keyword.get(opts, :metadata) || %{})
  end
end
