defmodule Mix.Tasks.PhoenixKitBilling.RefreshFxRates do
  @moduledoc """
  Refreshes `phoenix_kit_currencies.exchange_rate` from the optional
  `:fx_rate_provider` hook (per-domain-currency spec §6.1) — see
  `PhoenixKitBilling.refresh_rates_from_provider/1` for the full
  contract this task drives.

  Rates stay MANUAL by default in this application. Nothing calls this
  task on its own — no cron, no Oban worker is shipped with it — a host
  that wants periodic refresh runs it from their own scheduler.

  ## Usage

      $ mix phoenix_kit_billing.refresh_fx_rates
      $ mix phoenix_kit_billing.refresh_fx_rates --apply

  ## Options

    * `--apply` — write the accepted rates. Without it, this task DRY
      RUNS: it fetches and validates the provider's rates and prints
      what would change, without writing anything — the same discipline
      the rest of this codebase uses for anything that touches money.

  With no `:fx_rate_provider` configured this task prints a message and
  exits 0 — nothing to do is not a failure. A malformed or partially-bad
  provider response is refused as a whole (nothing written, in either
  mode) and every problem found is printed; the task then exits non-zero.
  """

  use Mix.Task

  @shortdoc "Refresh currency rates from the optional :fx_rate_provider hook"

  @switches [apply: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} = OptionParser.parse!(argv, strict: @switches)
    dry_run? = not Keyword.get(opts, :apply, false)

    Mix.Task.run("app.start")

    if dry_run? do
      Mix.shell().info("DRY RUN — no rates will be written. Pass --apply to write.\n")
    end

    dry_run?
    |> then(&PhoenixKitBilling.refresh_rates_from_provider(dry_run: &1))
    |> render()
  end

  defp render({:error, :no_provider}) do
    Mix.shell().info(
      "No :fx_rate_provider configured under :phoenix_kit — nothing to do. See " <>
        "PhoenixKitBilling.refresh_rates_from_provider/1 for the hook contract."
    )
  end

  defp render({:error, {:invalid_rates, issues}}) do
    Mix.raise(
      "fx_rate_provider returned invalid data — nothing was written:\n" <>
        Enum.map_join(issues, "\n", fn %{code: code, reason: reason} ->
          "  #{code}: #{reason}"
        end)
    )
  end

  defp render({:error, {:invalid_provider_response, raw}}) do
    Mix.raise(
      "fx_rate_provider did not return a map of currency code => rate, got: #{inspect(raw)}"
    )
  end

  defp render({:error, {:provider_raised, message}}) do
    Mix.raise("fx_rate_provider raised: #{message}")
  end

  defp render({:error, {:provider_exited, reason}}) do
    Mix.raise("fx_rate_provider exited: #{inspect(reason)}")
  end

  defp render({:ok, %{dry_run: true, would_update: would_update, skipped_base: skipped_base}}) do
    if would_update == [] do
      Mix.shell().info("No rates would change.")
    else
      Enum.each(would_update, fn %{code: code, current_rate: current, new_rate: new} ->
        Mix.shell().info("  #{code}: #{current} -> #{new}")
      end)
    end

    print_skipped_base(skipped_base)
  end

  defp render({:ok, %{updated: updated, skipped_base: skipped_base}}) do
    if updated == [] do
      Mix.shell().info("No rates were updated.")
    else
      Mix.shell().info("Updated: #{Enum.join(updated, ", ")}")
    end

    print_skipped_base(skipped_base)
  end

  defp print_skipped_base(codes) do
    Enum.each(codes, fn code ->
      Mix.shell().info("  #{code}: skipped (base currency, always 1.0)")
    end)
  end
end
