defmodule PhoenixKitBilling.Web.AuthzTest do
  @moduledoc """
  Sub-permission enforcement in the billing admin LiveViews, and the two
  contracts that keep the audit trail and the notification layer from
  doubling up.

  Before this the harness could not express a denied scope at all: every
  fixture handed out `["billing"]` with `roles: ["Owner"]`, so an
  authorization regression could not fail a test.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKitBilling.Web.Authz

  defp scope_with(permissions), do: fake_scope(roles: ["Employee"], permissions: permissions)

  describe "Authz.can?/2" do
    test "fails closed on a missing scope" do
      refute Authz.can?(%{assigns: %{}}, :manage_invoices)
      refute Authz.can?(%{assigns: %{phoenix_kit_current_scope: nil}}, :manage_invoices)
    end

    test "honours the specific capability, not the base key" do
      base = %{assigns: %{phoenix_kit_current_scope: scope_with(["billing"])}}

      invoices = %{
        assigns: %{phoenix_kit_current_scope: scope_with(["billing", "billing.manage_invoices"])}
      }

      refute Authz.can?(base, :manage_invoices)
      assert Authz.can?(invoices, :manage_invoices)
      # Holding one capability must not unlock a sibling: whoever chases
      # invoices is not thereby allowed to rotate a provider's API keys.
      refute Authz.can?(invoices, :manage_settings)
    end
  end

  describe "the declared capabilities are real" do
    test "every admin tab guards the base key or a declared sub-permission" do
      meta = PhoenixKitBilling.permission_metadata()
      valid = MapSet.new([meta.key | Enum.map(meta.sub_permissions, &"#{meta.key}.#{&1.key}")])

      for tab <- PhoenixKitBilling.admin_tabs() do
        assert MapSet.member?(valid, tab.permission),
               "tab #{inspect(tab.id)} guards #{inspect(tab.permission)}"
      end
    end

    test "every declared sub-permission is enforced somewhere" do
      # A declared-but-unenforced capability is worse than none: it appears
      # in the admin matrix, an operator grants or withholds it, and
      # nothing changes.
      %{sub_permissions: subs} = PhoenixKitBilling.permission_metadata()
      tab_keys = PhoenixKitBilling.admin_tabs() |> Enum.map(& &1.permission) |> MapSet.new()

      sources =
        Path.wildcard("lib/phoenix_kit_billing/web/**/*.ex")
        |> Enum.map_join("\n", &File.read!/1)

      for %{key: key} <- subs do
        assert MapSet.member?(tab_keys, "billing.#{key}") or sources =~ ":#{key}",
               "sub-permission billing.#{key} is declared but never enforced"
      end
    end

    test "every money mutation on the invoice page is gated" do
      source = File.read!("lib/phoenix_kit_billing/web/invoice_detail.ex")

      money_events = ~w(record_payment pay_with_provider record_refund void_invoice
                        send_invoice send_receipt send_credit_note
                        send_payment_confirmation generate_receipt)

      for event <- money_events do
        assert source =~
                 ~s|def handle_event("#{event}", params, socket) do\n    Authz.authorize(socket, :manage_invoices|,
               "#{event} is not behind the manage_invoices gate"
      end
    end
  end

  describe "notification contracts" do
    test "admin and customer audiences are separate sub-types" do
      [%{sub_types: subs}] = PhoenixKitBilling.notification_types()
      keys = Enum.map(subs, & &1.key)

      assert "invoices" in keys
      assert "your_billing" in keys
    end

    test "no action belongs to two sub-types" do
      [%{sub_types: subs}] = PhoenixKitBilling.notification_types()
      all = Enum.flat_map(subs, & &1.actions)

      assert all == Enum.uniq(all)
    end

    test "audit action strings are NOT registered notification actions" do
      # core's Activity.log/1 auto-derives notifications from registered
      # actions, so an audit row written with a notify action would deliver
      # a duplicate on top of the explicit fan-out.
      [%{sub_types: subs}] = PhoenixKitBilling.notification_types()
      registered = Enum.flat_map(subs, & &1.actions) |> MapSet.new()

      audit_actions =
        Path.wildcard("lib/phoenix_kit_billing/**/*.ex")
        |> Enum.flat_map(fn path ->
          Regex.scan(~r/Activity\.log\(\s*"([^"]+)"/, File.read!(path), capture: :all_but_first)
        end)
        |> List.flatten()
        |> Enum.uniq()

      for action <- audit_actions do
        refute MapSet.member?(registered, action),
               "audit action #{inspect(action)} is also a registered notification action - " <>
                 "Activity.log/1 would deliver a duplicate"
      end
    end
  end

  describe "sends are best-effort" do
    test "a malformed invoice does not raise" do
      assert :ok = PhoenixKitBilling.Notifications.invoice_issued(%{})
      assert :ok = PhoenixKitBilling.Notifications.payment_received(%{})
      assert :ok = PhoenixKitBilling.Notifications.payment_failed(%{}, :card_declined)
    end
  end
end
