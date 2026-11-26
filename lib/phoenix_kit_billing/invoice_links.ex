defmodule PhoenixKitBilling.InvoiceLinks do
  @moduledoc """
  Signed links to an invoice's public payment page, for a payer without an
  account (a guest invoice) or anyone else the operator sends one to.

  The token is a `Phoenix.Token` over the invoice's uuid: it names the invoice and
  proves billing issued it, and is the only credential the page asks for - so it
  is sent only to the payer. The page (`/billing/pay/:token`,
  `PhoenixKitBilling.Web.GuestInvoice`) shows the invoice and, while it can be
  paid, a button per available provider that opens the provider's hosted
  checkout through `PhoenixKitBilling.create_checkout_session/3`.

  ## Configuration

  - The signing secret is the host endpoint's `secret_key_base` (the endpoint
    from `config :phoenix_kit, endpoint:`, else the parent application's).
    `config :phoenix_kit_billing, invoice_link_secret: "..."` (at least 32 bytes)
    takes precedence, for a host that wants links it can revoke all at once by
    rotating it.
  - `config :phoenix_kit_billing, invoice_link_max_age: seconds` - how long a
    link works, default 180 days.

  A token for a draft (until it is sent) or an invoice in the trash finds
  nothing; a void or paid invoice is still shown (its status says so) but offers
  no payment.

  ## Revoking one invoice's links

  The token carries the invoice's link generation
  (`metadata["pay_link_generation"]`, 0 until first revoked). `revoke/1` moves it
  on, so every link issued for that invoice so far stops working and the next
  `pay_url/1` is a new one - for a link sent to the wrong address. Other
  invoices' links are untouched.
  """

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.{Invoice, Paths}

  import Ecto.Query, only: [from: 2]

  @salt "phoenix_kit_billing:invoice_link"
  @generation_key "pay_link_generation"
  @default_max_age 60 * 60 * 24 * 180

  @doc "A token for `invoice`'s payment page."
  @spec token(Invoice.t()) :: String.t()
  def token(%Invoice{uuid: uuid} = invoice) when is_binary(uuid) do
    Phoenix.Token.sign(secret!(), @salt, [uuid, generation(invoice)])
  end

  @doc "The page's path for `invoice` (host prefix and locale applied)."
  @spec pay_path(Invoice.t()) :: String.t()
  def pay_path(%Invoice{} = invoice), do: Paths.invoice_pay(token(invoice))

  @doc "The page's absolute URL for `invoice`, to put in an email."
  @spec pay_url(Invoice.t()) :: String.t()
  def pay_url(%Invoice{} = invoice), do: Routes.base_url() <> pay_path(invoice)

  @doc """
  The invoice a token names, or nil: an invalid, expired or revoked token, an
  invoice that is gone, still a draft or in the trash. Never raises.
  """
  @spec invoice_from_token(term()) :: Invoice.t() | nil
  def invoice_from_token(token) when is_binary(token) do
    with secret when is_binary(secret) <- secret(),
         {:ok, [uuid, generation]} when is_binary(uuid) <-
           Phoenix.Token.verify(secret, @salt, token, max_age: max_age()),
         %Invoice{} = invoice <- PhoenixKitBilling.get_invoice(uuid, preload: [:order, :user]),
         true <- generation(invoice) == generation,
         true <- issued?(invoice) do
      invoice
    else
      _ -> nil
    end
  end

  def invoice_from_token(_token), do: nil

  @doc """
  Revokes every payment link issued for `invoice` so far; the next `pay_url/1` is
  a new one. Returns `{:ok, invoice}` or `{:error, :invoice_not_found}`.
  """
  @spec revoke(Invoice.t()) :: {:ok, Invoice.t()} | {:error, term()}
  def revoke(%Invoice{uuid: uuid}) do
    repo = PhoenixKit.RepoHelper.repo()

    repo.transaction(fn ->
      query = from(i in Invoice, where: i.uuid == ^uuid, lock: "FOR UPDATE")

      with %Invoice{} = locked <- repo.one(query),
           metadata = Map.put(locked.metadata || %{}, @generation_key, generation(locked) + 1),
           {:ok, updated} <- locked |> Ecto.Changeset.change(metadata: metadata) |> repo.update() do
        updated
      else
        nil -> repo.rollback(:invoice_not_found)
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  end

  # A draft is not issued yet (its amounts can still change) and an invoice in the
  # trash is gone: a link opens neither. A link made for a draft works once the
  # invoice is sent.
  defp issued?(%Invoice{status: "draft"}), do: false
  defp issued?(invoice), do: not Invoice.trashed?(invoice)

  defp generation(%Invoice{metadata: %{@generation_key => generation}})
       when is_integer(generation),
       do: generation

  defp generation(_invoice), do: 0

  @doc "Whether links can be signed here (a secret is configured)."
  @spec available?() :: boolean()
  def available?, do: is_binary(secret())

  defp max_age,
    do: Application.get_env(:phoenix_kit_billing, :invoice_link_max_age, @default_max_age)

  defp secret! do
    secret() ||
      raise ArgumentError,
            "no secret to sign invoice links with: set the endpoint's secret_key_base " <>
              "or config :phoenix_kit_billing, invoice_link_secret: ..."
  end

  defp secret do
    usable(Application.get_env(:phoenix_kit_billing, :invoice_link_secret)) ||
      endpoint_secret()
  end

  defp endpoint_secret do
    case endpoint() do
      nil -> nil
      endpoint -> usable(endpoint.config(:secret_key_base))
    end
  rescue
    _ -> nil
  end

  defp endpoint do
    case PhoenixKit.Config.get(:endpoint) do
      {:ok, endpoint} when is_atom(endpoint) and not is_nil(endpoint) ->
        endpoint

      _ ->
        case PhoenixKit.Config.get_parent_endpoint() do
          {:ok, endpoint} -> endpoint
          _ -> nil
        end
    end
  end

  defp usable(secret) when is_binary(secret) and byte_size(secret) >= 32, do: secret
  defp usable(_secret), do: nil
end
