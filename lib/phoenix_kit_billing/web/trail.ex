defmodule PhoenixKitBilling.Web.Trail do
  @moduledoc """
  Sets the assigns core's admin header draws its breadcrumb from —
  `page_section` (+ `page_section_path`), `page_crumbs` and `page_title` —
  the same way on every billing admin page.

  The header bar renders `Admin Panel / section / crumb… / title` and owns
  the separators; a page only says where it is. The section is the module
  (its admin tab label, linking to the landing page), or `Settings` for the
  pages under `/admin/settings/billing`; the crumbs are every level between
  the section and the page; the title is this page alone — never a joined
  trail like "Billing — Orders". A record's number or name is data and is
  not translated. The shapes per page type are in core's
  `dev_docs/guides/2026-09-25-admin-header-trail.md`.
  """

  use Gettext, backend: PhoenixKitBilling.Gettext

  import Phoenix.Component, only: [assign: 2]

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Paths

  @doc """
  The module landing page (`/admin/billing`): the module is the title, so
  there is no section and no crumbs.
  """
  def landing(socket) do
    assign(socket,
      page_section: nil,
      page_section_path: nil,
      page_crumbs: [],
      page_title: gettext("Billing")
    )
  end

  @doc """
  A page under the module: `Billing / crumbs… / title`.
  """
  def billing(socket, title, crumbs \\ []) do
    assign(socket,
      page_section: gettext("Billing"),
      page_section_path: Paths.billing_index(),
      page_crumbs: crumbs,
      page_title: title
    )
  end

  @doc """
  A page under `/admin/settings/billing`: `Settings / crumbs… / title`.
  It lives in Settings, not in the module.
  """
  def settings(socket, title, crumbs \\ []) do
    assign(socket,
      page_section: gettext("Settings"),
      page_section_path: Routes.path("/admin/settings"),
      page_crumbs: crumbs,
      page_title: title
    )
  end

  @doc """
  One crumb. With a path it links there; without one it renders as text,
  which is only for a level that has no page of its own.
  """
  def crumb(label, path \\ nil)
  def crumb(label, nil), do: %{label: label}
  def crumb(label, path), do: %{label: label, path: path}

  # The list-page crumbs, labelled like the admin tabs they mirror.

  def orders, do: crumb(gettext("Orders"), Paths.orders())
  def invoices, do: crumb(gettext("Invoices"), Paths.invoices())
  def subscriptions, do: crumb(gettext("Subscriptions"), Paths.subscriptions())
  def subscription_types, do: crumb(gettext("Subscription Types"), Paths.subscription_types())
  def billing_profiles, do: crumb(gettext("Billing Profiles"), Paths.billing_profiles())

  @doc "The billing settings page, as a crumb for its sub-pages."
  def billing_settings, do: crumb(gettext("Billing"), Paths.settings())
end
