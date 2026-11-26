defmodule PhoenixKitBilling.Web.CSPInlineTagsTest do
  @moduledoc """
  What a host's nonce-based Content-Security-Policy blocks stays out of this
  package: every inline `<script>` and `<style>` carries the nonce
  (`PhoenixKitBilling.Web.CSP.nonce/1`), and nothing carries an inline event
  handler, which no nonce can cover. Modelled on core's
  `PhoenixKitWeb.CSPInlineTagsTest`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBilling.Web.CSP

  @root Path.expand("../../..", __DIR__)
  @bundle "priv/static/assets/phoenix_kit_billing.js"
  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  # Deliberately without a nonce. E-mail bodies: a mail client never sees the
  # host's policy, and a nonce in a mail would be a dead attribute.
  @exempt []

  @tag_opening ~r/<(script|style)\b[^>]*>/s

  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!("\\son[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]")
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- sources("lib/**/*.{ex,heex}"),
          path not in @exempt,
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          not (opening =~ "CSP.nonce("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without `nonce={PhoenixKitBilling.Web.CSP.nonce(kind)}`:\n" <>
             Enum.join(offenders, "\n")
  end

  test "the scan sees the print pages' <style> tags" do
    for page <- ~w(invoice_print receipt_print credit_note_print payment_confirmation_print) do
      assert [{opening, _line}] = tag_openings("lib/phoenix_kit_billing/web/#{page}.html.heex")
      assert opening =~ "<style" and opening =~ "CSP.nonce(:style)"
    end
  end

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- sources("lib/**/*.{ex,heex}"),
          {line, number} <- path |> read() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use `data-pkb-*` handled in " <>
             "#{@bundle}, or a `phx-` binding):\n" <> Enum.join(offenders, "\n")
  end

  test "the handler pattern matches what it is for" do
    assert ~S|<button onclick="window.print()">| =~ @handler
    assert ~S|<button onclick={"copy()"}>| =~ @handler
    assert ~S|<form onsubmit = 'return false'>| =~ @handler
    assert ~S|<a href="javascript:void(0)">| =~ @js_url
    refute ~S|<button phx-click="save" data-pkb-print>| =~ @handler
    refute ~S|only = "x"| =~ @handler
  end

  test "the bundle builds no inline handler and no unstamped <style> or <script>" do
    offenders =
      for {line, number} <- @bundle |> read() |> String.split("\n") |> Enum.with_index(1),
          not (line =~ ~r{^\s*(//|/?\*)}),
          line =~ ~r/\son[a-z]+=\\?["']/ or line =~ ~r/createElement\(["'](?:style|script)["']\)/ or
            line =~ ~r/["'`]<(?:style|script)\b/,
          do: "#{@bundle}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  test "nonce/1 answers nil or a string, whichever core is installed" do
    for kind <- [:script, :style] do
      nonce = CSP.nonce(kind)
      assert is_nil(nonce) or is_binary(nonce)
    end
  end

  test "nonce/1 is core's nonce where core has one" do
    if Code.ensure_loaded?(PhoenixKitWeb.CSP) and function_exported?(PhoenixKitWeb.CSP, :nonce, 1) do
      # The way a live session hands the page's nonces to a LiveView process.
      session = %{"phoenix_kit_csp_nonces" => %{"style" => "style-nonce"}}

      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      # Through a variable: the published core has no such module to name.
      core = PhoenixKitWeb.CSP
      {:cont, _socket} = core.on_mount(:default, %{}, session, %Phoenix.LiveView.Socket{})

      assert CSP.nonce(:style) == "style-nonce"
      assert CSP.nonce(:script) == nil
    else
      assert CSP.nonce(:style) == nil
    end
  end

  defp sources(glob) do
    @root |> Path.join(glob) |> Path.wildcard() |> Enum.map(&Path.relative_to(&1, @root))
  end

  defp read(path), do: @root |> Path.join(path) |> File.read!()

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> read() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
