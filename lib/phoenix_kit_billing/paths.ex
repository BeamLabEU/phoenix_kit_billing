defmodule PhoenixKitBilling.Paths do
  @moduledoc "Centralized path helpers for Billing module."
  alias PhoenixKit.Utils.Routes

  @base "/admin/billing"
  @user_base "/dashboard"

  def billing_index, do: Routes.path(@base)
  def orders, do: Routes.path("#{@base}/orders")
  def order_new, do: Routes.path("#{@base}/orders/new")
  def order_detail(id), do: Routes.path("#{@base}/orders/#{id}")
  def order_edit(id), do: Routes.path("#{@base}/orders/#{id}/edit")
  def invoices, do: Routes.path("#{@base}/invoices")
  def invoice_detail(id), do: Routes.path("#{@base}/invoices/#{id}")
  def invoice_print(id), do: Routes.path("#{@base}/invoices/#{id}/print")
  def receipt_print(id), do: Routes.path("#{@base}/invoices/#{id}/receipt")

  def credit_note(id, txn_uuid),
    do: Routes.path("#{@base}/invoices/#{id}/credit-note/#{txn_uuid}")

  def payment_confirmation(id, txn_uuid),
    do: Routes.path("#{@base}/invoices/#{id}/payment-confirmation/#{txn_uuid}")

  def transactions, do: Routes.path("#{@base}/transactions")
  def subscriptions, do: Routes.path("#{@base}/subscriptions")
  def subscription_new, do: Routes.path("#{@base}/subscriptions/new")
  def subscription_detail(id), do: Routes.path("#{@base}/subscriptions/#{id}")
  def subscription_types, do: Routes.path("#{@base}/subscription-types")
  def subscription_type_new, do: Routes.path("#{@base}/subscription-types/new")
  def subscription_type_edit(id), do: Routes.path("#{@base}/subscription-types/#{id}/edit")
  def billing_profiles, do: Routes.path("#{@base}/profiles")
  def billing_profile_new, do: Routes.path("#{@base}/profiles/new")
  def billing_profile_edit(id), do: Routes.path("#{@base}/profiles/#{id}/edit")
  def currencies, do: Routes.path("#{@base}/currencies")
  def settings, do: Routes.path("/admin/settings/billing")
  def provider_settings, do: Routes.path("/admin/settings/billing/providers")

  # Customer-facing pages. These mirror `user_dashboard_tabs/0` — the tabs
  # this module registers are the only customer routes guaranteed to exist.
  def user_orders, do: Routes.path("#{@user_base}/billing-orders")
  def user_billing_profiles, do: Routes.path("#{@user_base}/billing-profiles")

  # Bare dashboard root — unconditionally registered by core whenever
  # `PhoenixKit.Config.user_dashboard_enabled?()` is true, unlike the tabs
  # above which only exist when this module's own `:live_view` wiring does.
  # Used as a safe fallback target when a more specific customer route isn't
  # guaranteed to exist yet.
  def dashboard_root, do: Routes.path(@user_base)
end
