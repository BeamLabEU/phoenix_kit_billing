defmodule PhoenixKitBilling.Web.CSP do
  @moduledoc """
  The host's Content-Security-Policy nonce for the inline `<style>` tags this
  package renders (the print pages).

      <style nonce={PhoenixKitBilling.Web.CSP.nonce(:style)}>

  The nonce is core's (`PhoenixKitWeb.CSP`), which a core older than that
  module does not have: there this returns `nil`, HEEx renders no attribute,
  and the page is what it was before. No nonce can be put on an attribute, so
  the templates carry no inline event handler; `data-pkb-print` and
  `data-pkb-copy` name what a button does and
  `priv/static/assets/phoenix_kit_billing.js` does it.

  `test/phoenix_kit_billing/web/csp_inline_tags_test.exs` fails on an inline
  tag without the nonce and on an inline handler.
  """

  @type kind :: :script | :style

  @doc "The nonce of the current page for `kind`, or `nil` (none set, or an older core)."
  @spec nonce(kind) :: String.t() | nil
  def nonce(kind) when kind in [:script, :style] do
    if Code.ensure_loaded?(PhoenixKitWeb.CSP) and function_exported?(PhoenixKitWeb.CSP, :nonce, 1) do
      # `apply/3`: the published core has no such module to call by name.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(PhoenixKitWeb.CSP, :nonce, [kind])
    end
  end
end
