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
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  @logo_key "billing_document_logo_file_uuid"
  @footer_key "billing_document_footer"
  @project_logo_key "auth_logo_file_uuid"

  # The file the printed documents show. Every finished upload has it,
  # whatever its type — an SVG has no resized sizes at all.
  @logo_variant "original"

  # Sizes tried for the email logo, smallest first — the same order as core's
  # own email logo (`PhoenixKit.Email.Branding`).
  @email_logo_variants ~w(small medium large original)

  # Core stores a setting's value in at most this many characters.
  @footer_max_length 1000

  # The footer text in an email; an email has no stylesheet.
  @footer_style "margin:0 0 16px;color:#52525b;font-size:13px;line-height:1.5;"

  # Types every mail client shows. Not SVG, not WebP (Outlook for Windows).
  @email_image_types ~w(image/png image/jpeg image/gif)

  @doc "The settings key holding the logo's media-library file uuid."
  @spec logo_key() :: String.t()
  def logo_key, do: @logo_key

  @doc "The settings key holding the footer text."
  @spec footer_key() :: String.t()
  def footer_key, do: @footer_key

  @doc "The longest footer text a setting can hold, in characters."
  @spec footer_max_length() :: pos_integer()
  def footer_max_length, do: @footer_max_length

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
  else the project logo — or `nil` when neither is set, or the file is one the
  file route will not serve: in the trash, gone, system-managed, or in a
  private library. The documents then print the company name instead.
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

    * `"document_footer"` — `footer_text/0`, always present (`""` when unset),
      for the plain-text body.
    * `"document_footer_html"` — the same text as one escaped, inline-styled
      paragraph with its line breaks kept, for the HTML body (`""` when unset).
    * `"logo_url"` — an absolute, versioned URL of the **billing** logo's
      smallest finished size every mail client shows (PNG, JPEG or GIF;
      small, then medium, large, original), only when one is set. Left out
      otherwise, so core's layout keeps the site's own logo
      (`PhoenixKit.Email.Branding`) — a blank value would hide it.
  """
  @spec email_variables() :: %{String.t() => String.t()}
  def email_variables do
    footer = footer_text()
    variables = %{"document_footer" => footer, "document_footer_html" => footer_html(footer)}

    case email_logo_url() do
      nil -> variables
      url -> Map.put(variables, "logo_url", url)
    end
  end

  @doc """
  `text` as one escaped, inline-styled paragraph with its line breaks kept —
  the footer text in an HTML email. `""` for no text.
  """
  @spec footer_html(String.t()) :: String.t()
  def footer_html(""), do: ""

  def footer_html(text) when is_binary(text) do
    lines =
      text
      |> String.split(~r/\R/u)
      |> Enum.map_join(
        "<br>",
        &(&1 |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string())
      )

    ~s(<p style="#{@footer_style}">) <> lines <> "</p>"
  end

  defp email_logo_url do
    with {:ok, file} <- logo_file(@logo_key),
         %{variant_name: variant} = instance <- email_instance(file.uuid) do
      Routes.base_url() <> URLSigner.signed_url(file.uuid, variant, version: instance)
    else
      _ -> nil
    end
  end

  defp email_instance(uuid) do
    instances =
      uuid
      |> Storage.list_file_instances()
      |> Enum.filter(
        &(&1.processing_status == "completed" and &1.mime_type in @email_image_types)
      )
      |> Map.new(&{&1.variant_name, &1})

    Enum.find_value(@email_logo_variants, &Map.get(instances, &1))
  end

  defp logo_file(key) do
    with uuid when is_binary(uuid) and uuid != "" <- Settings.get_setting(key, ""),
         true <- UUIDUtils.valid?(uuid),
         %{trashed_at: nil} = file <- Storage.get_file(uuid),
         false <- Map.get(file, :system_managed, false),
         false <- Libraries.private_file?(file) do
      {:ok, file}
    else
      _ -> :error
    end
  rescue
    error ->
      Logger.warning("Billing document logo lookup failed: #{inspect(error)}")
      :error
  end
end
