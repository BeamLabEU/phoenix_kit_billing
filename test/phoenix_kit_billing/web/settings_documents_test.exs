defmodule PhoenixKitBilling.Web.SettingsDocumentsTest do
  @moduledoc """
  Billing → Settings → Printed documents: the logo and the footer text the
  printable documents and the financial emails carry.
  """

  use PhoenixKitBilling.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.DocumentBranding

  @path "/en/admin/settings/billing"

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "shows the saved footer text", %{conn: conn} do
    Settings.update_setting(DocumentBranding.footer_key(), "About us")

    {:ok, view, _html} = live(conn, @path)

    assert has_element?(
             view,
             "#billing-documents-form textarea[name=document_footer]",
             "About us"
           )
  end

  test "saves the footer text and the logo picked from the media library", %{conn: conn} do
    uuid = UUIDv7.generate()
    {:ok, view, _html} = live(conn, @path)

    view |> element("#billing-document-logo-select") |> render_click()
    send(view.pid, {:media_selected, [uuid]})

    view
    |> form("#billing-documents-form", %{"document_footer" => "  Acme — tools for home.\n"})
    |> render_submit()

    assert Settings.get_setting(DocumentBranding.footer_key()) == "Acme — tools for home."
    assert Settings.get_setting(DocumentBranding.logo_key()) == uuid
  end

  test "removes the logo", %{conn: conn} do
    Settings.update_setting(DocumentBranding.logo_key(), UUIDv7.generate())
    {:ok, view, _html} = live(conn, @path)

    view |> element("#billing-document-logo-remove") |> render_click()
    view |> form("#billing-documents-form", %{"document_footer" => ""}) |> render_submit()

    assert Settings.get_setting(DocumentBranding.logo_key(), "") == ""
    assert has_element?(view, "#billing-document-logo-select")
  end

  test "an operator without manage_settings cannot change them", %{conn: conn} do
    scope = fake_scope(permissions: ["billing"], roles: ["Employee"])
    {:ok, view, _html} = live(put_test_scope(conn, scope), @path)

    view
    |> form("#billing-documents-form", %{"document_footer" => "Hijacked"})
    |> render_submit()

    assert Settings.get_setting(DocumentBranding.footer_key(), "") == ""
  end
end
