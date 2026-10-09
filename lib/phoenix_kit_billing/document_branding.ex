defmodule PhoenixKitBilling.DocumentBranding do
  @moduledoc """
  The seller's branding on billing documents: a logo at the top of the
  printable invoice, receipt, credit note and payment confirmation, and a
  short text about the company at their foot. Both are settings, edited under
  Billing → Settings:

    * `billing_document_logo_file_uuid` — a file from the media library.
      Unset, the project logo (`auth_logo_file_uuid`) is used; with neither,
      the documents print the company name instead.
    * `billing_document_footer` — free text, printed as written (line breaks
      kept). A typical one says what the company does, how to reach it, and
      what the prices include.

  The financial emails carry the footer text too, and the billing logo in the
  header of the billing layout — see `email_variables/0`.

  Both are read on every render, so a changed setting shows on the next
  document without a restart.
  """

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  @logo_key "billing_document_logo_file_uuid"
  @footer_key "billing_document_footer"
  @project_logo_key "auth_logo_file_uuid"

  # The file served for the logo. Every finished upload has it, whatever its
  # type — an SVG has no resized sizes at all.
  @logo_variant "original"

  # Types every mail client shows. Not SVG, not WebP (Outlook for Windows).
  @email_image_types ~w(image/png image/jpeg image/gif)

  @doc "The settings key holding the logo's media-library file uuid."
  @spec logo_key() :: String.t()
  def logo_key, do: @logo_key

  @doc "The settings key holding the footer text."
  @spec footer_key() :: String.t()
  def footer_key, do: @footer_key

  @doc """
  The footer text as set, trimmed; `""` when unset.
  """
  @spec footer_text() :: String.t()
  def footer_text do
    case Settings.get_setting(@footer_key, "") do
      text when is_binary(text) -> String.trim(text)
      _ -> ""
    end
  end

  @doc """
  A URL of the document logo for the printable documents — the billing logo,
  else the project logo — or `nil` when neither is set, or the file is in the
  trash or no longer exists.
  """
  @spec logo_url() :: String.t() | nil
  def logo_url do
    Enum.find_value([@logo_key, @project_logo_key], fn key ->
      case logo_file(key) do
        {:ok, file} -> file_url(file.uuid)
        :error -> nil
      end
    end)
  end

  @doc "A URL of a media-library file's original, as the documents show it."
  @spec file_url(String.t()) :: String.t()
  def file_url(uuid) when is_binary(uuid), do: URLSigner.signed_url(uuid, @logo_variant)

  @doc """
  The branding variables for a financial email:

    * `"document_footer"` — `footer_text/0`, always present (`""` when unset).
    * `"logo_url"` — an absolute URL of the **billing** logo, only when one
      is set and it is an image every mail client shows (PNG, JPEG or GIF)
      outside a private library. Left out otherwise, so core's layout keeps
      the site's own logo (`PhoenixKit.Email.Branding`) — a blank value
      would hide it.
  """
  @spec email_variables() :: %{String.t() => String.t()}
  def email_variables do
    variables = %{"document_footer" => footer_text()}

    case email_logo_url() do
      nil -> variables
      url -> Map.put(variables, "logo_url", url)
    end
  end

  defp email_logo_url do
    with {:ok, file} <- logo_file(@logo_key),
         true <- file.mime_type in @email_image_types,
         false <- private_file?(file) do
      Routes.base_url() <> file_url(file.uuid)
    else
      _ -> nil
    end
  end

  defp logo_file(key) do
    with uuid when is_binary(uuid) and uuid != "" <- Settings.get_setting(key, ""),
         true <- UUIDUtils.valid?(uuid),
         %{} = file <- Storage.get_file(uuid),
         nil <- Map.get(file, :trashed_at) do
      {:ok, file}
    else
      _ -> :error
    end
  rescue
    error ->
      Logger.warning("Billing document logo lookup failed: #{inspect(error)}")
      :error
  end

  # Libraries arrived in a later core than this module's floor; before them
  # no file is private.
  defp private_file?(file) do
    libraries = PhoenixKit.Modules.Storage.Libraries

    Code.ensure_loaded?(libraries) and function_exported?(libraries, :private_file?, 1) and
      libraries.private_file?(file)
  end
end
