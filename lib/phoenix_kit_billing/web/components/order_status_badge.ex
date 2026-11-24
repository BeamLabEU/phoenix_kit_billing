defmodule PhoenixKitBilling.Web.Components.OrderStatusBadge do
  @moduledoc """
  Provides order status badge components for the billing system.

  Supports all order lifecycle statuses with appropriate color coding.
  Follows daisyUI badge styling conventions.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitBilling.Gettext

  @doc """
  Renders an order status badge with appropriate styling.

  ## Attributes
  - `status` - Order status string (required)
  - `size` - Badge size: :xs, :sm, :md, :lg (default: :sm)
  - `class` - Additional CSS classes

  ## Supported Statuses
  - `draft` - Order in draft state (ghost/gray)
  - `pending` - Order pending confirmation (warning/yellow)
  - `confirmed` - Order confirmed (info/blue)
  - `paid` - Order paid successfully (success/green)
  - `cancelled` - Order cancelled (error/red)
  - `refunded` - Order refunded (secondary/purple)

  ## Examples

      <.order_status_badge status="paid" />
      <.order_status_badge status="pending" size={:md} />
      <.order_status_badge status={@order.status} class="ml-2" />
  """
  attr(:status, :string, required: true)
  attr(:size, :atom, default: :sm, values: [:xs, :sm, :md, :lg])
  attr(:class, :string, default: "")

  def order_status_badge(assigns) do
    ~H"""
    <span class={["badge", status_class(@status), size_class(@size), @class]}>
      {format_status(@status)}
    </span>
    """
  end

  # Private helper functions

  # Order status badge classes
  defp status_class("draft"), do: "badge-ghost"
  defp status_class("pending"), do: "badge-warning"
  defp status_class("confirmed"), do: "badge-info"
  defp status_class("paid"), do: "badge-success"
  defp status_class("cancelled"), do: "badge-error"
  defp status_class("refunded"), do: "badge-secondary"

  defp status_class(status)
       when is_atom(status) and not is_nil(status) and not is_boolean(status),
       do: status |> Atom.to_string() |> status_class()

  defp status_class(_), do: "badge-ghost"

  # The status in the reader's language, in the "order status" context: the
  # plain msgids are shared with filters, timeline rows and subscription
  # pages, where a language with grammatical gender needs another form. A
  # status without a label shows as the raw value, and nil/booleans as nothing,
  # rather than failing the page.
  defp format_status(nil), do: ""
  defp format_status(status) when is_boolean(status), do: ""
  defp format_status("draft"), do: pgettext("order status", "Draft")
  defp format_status("pending"), do: pgettext("order status", "Pending")
  defp format_status("confirmed"), do: pgettext("order status", "Confirmed")
  defp format_status("paid"), do: pgettext("order status", "Paid")
  defp format_status("cancelled"), do: pgettext("order status", "Cancelled")
  defp format_status("refunded"), do: pgettext("order status", "Refunded")
  defp format_status(status) when is_binary(status), do: String.capitalize(status)

  defp format_status(status) when is_atom(status),
    do: status |> Atom.to_string() |> format_status()

  defp format_status(_status), do: ""

  # Size classes
  defp size_class(:xs), do: "badge-xs"
  defp size_class(:sm), do: "badge-sm"
  defp size_class(:md), do: "badge-md"
  defp size_class(:lg), do: "badge-lg"
end
