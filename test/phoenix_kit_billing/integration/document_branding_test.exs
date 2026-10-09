defmodule PhoenixKitBilling.Integration.DocumentBrandingTest do
  @moduledoc """
  `PhoenixKitBilling.DocumentBranding` — the logo and the footer text the
  printable documents and the financial emails carry, read from settings.
  """

  use PhoenixKitBilling.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.DocumentBranding
  alias PhoenixKitBilling.Test.Repo

  defp insert_file!(attrs \\ %{}) do
    defaults = %{
      original_file_name: "logo.png",
      file_name: "logo.png",
      mime_type: "image/png",
      file_type: "image",
      ext: "png",
      file_checksum: "checksum-#{System.unique_integer([:positive])}",
      user_file_checksum: "user-checksum-#{System.unique_integer([:positive])}",
      size: 1024,
      status: "active"
    }

    struct(PhoenixKit.Modules.Storage.File, Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_instance!(file, variant, attrs \\ %{}) do
    defaults = %{
      variant_name: variant,
      file_name: "#{variant}.png",
      mime_type: "image/png",
      ext: "png",
      checksum: "0123456789abcdef#{variant}",
      size: 512,
      processing_status: "completed",
      file_uuid: file.uuid
    }

    struct(PhoenixKit.Modules.Storage.FileInstance, Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp private_library! do
    user = fixture_user()

    struct(PhoenixKit.Modules.Storage.Library, %{
      name: "Private",
      kind: "user",
      visibility: "private",
      owner_uuid: user.uuid
    })
    |> Repo.insert!()
  end

  describe "footer_text/0" do
    test "is the setting, trimmed" do
      Settings.update_setting(DocumentBranding.footer_key(), "  «Acme» — tools for home.\n")

      assert DocumentBranding.footer_text() == "«Acme» — tools for home."
    end

    test "is empty when nothing is set" do
      assert DocumentBranding.footer_text() == ""
    end
  end

  describe "logo_url/0" do
    test "is nil when no logo is set" do
      assert DocumentBranding.logo_url() == nil
    end

    test "is a signed URL of the billing logo's original" do
      file = insert_file!()
      Settings.update_setting(DocumentBranding.logo_key(), file.uuid)

      url = DocumentBranding.logo_url()
      assert url =~ "/file/#{file.uuid}/original/"
    end

    test "falls back to the project logo" do
      file = insert_file!()
      Settings.update_setting("auth_logo_file_uuid", file.uuid)

      assert DocumentBranding.logo_url() =~ "/file/#{file.uuid}/original/"
    end

    test "is nil for a file that is gone or in the trash" do
      Settings.update_setting(DocumentBranding.logo_key(), UUIDv7.generate())
      assert DocumentBranding.logo_url() == nil

      trashed = insert_file!(%{trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)})
      Settings.update_setting(DocumentBranding.logo_key(), trashed.uuid)
      assert DocumentBranding.logo_url() == nil
    end

    test "is nil for a file the file route will not serve" do
      system = insert_file!(%{system_managed: true})
      Settings.update_setting(DocumentBranding.logo_key(), system.uuid)
      assert DocumentBranding.logo_url() == nil

      private = insert_file!(%{library_uuid: private_library!().uuid})
      Settings.update_setting(DocumentBranding.logo_key(), "")
      Settings.update_setting("auth_logo_file_uuid", private.uuid)
      assert DocumentBranding.logo_url() == nil
    end

    test "is nil for a setting that is not a uuid" do
      Settings.update_setting(DocumentBranding.logo_key(), "not-a-uuid")

      assert DocumentBranding.logo_url() == nil
    end
  end

  describe "email_variables/0" do
    test "carries the footer text and an absolute, versioned URL of the smallest mail-safe size" do
      file = insert_file!()
      insert_instance!(file, "original")
      insert_instance!(file, "medium")
      insert_instance!(file, "small", %{mime_type: "image/webp", ext: "webp"})
      Settings.update_setting(DocumentBranding.logo_key(), file.uuid)
      Settings.update_setting(DocumentBranding.footer_key(), "About us")

      variables = DocumentBranding.email_variables()

      assert variables["document_footer"] == "About us"

      assert variables["logo_url"] =~
               ~r{\Ahttps?://[^/]+/.*file/#{file.uuid}/medium/[^?]+\?v=0123456789abcdef\z}
    end

    test "leaves logo_url out while no mail-safe size is finished" do
      file = insert_file!()
      insert_instance!(file, "original", %{processing_status: "processing"})
      Settings.update_setting(DocumentBranding.logo_key(), file.uuid)

      refute Map.has_key?(DocumentBranding.email_variables(), "logo_url")
    end

    test "leaves logo_url out for a logo in a private library" do
      file = insert_file!(%{library_uuid: private_library!().uuid})
      insert_instance!(file, "small")
      Settings.update_setting(DocumentBranding.logo_key(), file.uuid)

      refute Map.has_key?(DocumentBranding.email_variables(), "logo_url")
    end

    test "carries the footer text as escaped HTML with its line breaks, for the HTML body" do
      Settings.update_setting(
        DocumentBranding.footer_key(),
        "«Acme» <tools>\r\nПобутова хімія.\nPrices are final."
      )

      html = DocumentBranding.email_variables()["document_footer_html"]

      assert html =~ "«Acme» &lt;tools&gt;<br>Побутова хімія.<br>Prices are final.</p>"
      assert html =~ ~r/\A<p style="[^"]+">/
    end

    test "leaves logo_url out for an image an email client may not show" do
      file = insert_file!(%{mime_type: "image/svg+xml", ext: "svg", file_name: "logo.svg"})
      Settings.update_setting(DocumentBranding.logo_key(), file.uuid)

      refute Map.has_key?(DocumentBranding.email_variables(), "logo_url")
    end

    test "leaves logo_url out without a billing logo, so the site's own logo stays" do
      file = insert_file!()
      Settings.update_setting("auth_logo_file_uuid", file.uuid)

      variables = DocumentBranding.email_variables()

      refute Map.has_key?(variables, "logo_url")
      assert variables["document_footer"] == ""
      assert variables["document_footer_html"] == ""
    end
  end
end
