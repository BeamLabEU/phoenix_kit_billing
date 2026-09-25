defmodule PhoenixKitBilling.Web.Components.SubscriptionHelpers do
  @moduledoc """
  Shared helper functions for subscription-related LiveViews.

  Provides formatting and display utilities used across subscription list,
  detail, form, and subscription type pages.
  """

  use Gettext, backend: PhoenixKitBilling.Gettext

  @doc """
  The name a subscription goes by in the header trail: its type's name.
  A subscription has no number of its own.
  """
  def subscription_name(%{subscription_type: %{name: name}}) when is_binary(name), do: name
  def subscription_name(_subscription), do: gettext("Subscription")

  @doc """
  Returns the daisyUI badge class for a subscription status.
  """
  def status_badge_class(status) do
    case status do
      "active" -> "badge-success"
      "trialing" -> "badge-info"
      "past_due" -> "badge-warning"
      "paused" -> "badge-neutral"
      "cancelled" -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  @doc """
  Formats a billing interval into a human-readable string.
  """
  def format_interval(nil, _), do: "-"
  def format_interval(_, nil), do: "-"

  def format_interval(interval, interval_count) do
    case {interval, interval_count} do
      {"month", 1} -> gettext("Monthly")
      {"month", n} -> ngettext("Every %{count} months", "Every %{count} months", n, count: n)
      {"year", 1} -> gettext("Yearly")
      {"year", n} -> ngettext("Every %{count} years", "Every %{count} years", n, count: n)
      {"week", 1} -> gettext("Weekly")
      {"week", n} -> ngettext("Every %{count} weeks", "Every %{count} weeks", n, count: n)
      {"day", 1} -> gettext("Daily")
      {"day", n} -> ngettext("Every %{count} days", "Every %{count} days", n, count: n)
      _ -> "#{interval_count} #{interval}(s)"
    end
  end
end
