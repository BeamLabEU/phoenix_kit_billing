# Code Review: PR #38 — Per-domain currency, stage Э5: optional exchange-rate provider hook

**Reviewed:** 2026-09-08
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/38
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 3c4de8d (branch `feature/currency-e5`, 4 commits:
03fc4c6, 934a589's line is unrelated/interleaved from #37 — the branch's own
commits are 03fc4c6, 1f4e74e, 23331b7, 3c4de8d)
**Status:** Merged

## Summary

Adds `PhoenixKitBilling.refresh_rates_from_provider/1` (§6.1): an optional
hook, `config :phoenix_kit, :fx_rate_provider, {mod, fun}`, that a host can
configure to pull exchange rates from an external feed. Rates stay manual by
default — nothing in this package calls this on its own. Ships:

- Full validation before any write (`:unknown_currency`, `:invalid_rate`,
  `:non_positive_rate`, `:rate_too_small` / `:rate_too_large` against the
  `numeric(15,6)` column's actual precision, `:invalid_code`), refusing the
  whole batch on any single bad entry.
- Case-insensitive currency-code normalization (`"eur"`/`"EUR"` collapse to
  one write).
- The base currency is silently skipped (never written; its rate is `1.0` by
  definition), reported back under `:skipped_base`.
- One transaction for validation + writes, opened by taking a
  `SELECT ... FOR UPDATE` lock on the current default-currency row first —
  the PR's key correctness claim is that this makes it impossible for a
  concurrent `set_default_currency/1` or `change_base_currency/2` to
  interleave with this write, because both of those functions' first write
  is an unconditional, no-`WHERE` `update_all` across every currency row
  (which always touches whichever row is currently default).
- A `:dry_run` option that runs the full fetch/validate pass but writes
  nothing.
- A deliberate double-broadcast: `update_currency/2`'s own in-transaction
  cache-invalidate-and-broadcast is documented as *not enough* under real
  Postgres (a READ COMMITTED subscriber reacting to it mid-transaction would
  re-read the pre-refresh row and repopulate the cache with stale data), so
  this function re-invalidates and re-broadcasts once more, itself, only
  after `repo().transaction/1` has actually returned `{:ok, _}`.
- A mix task, `phoenix_kit_billing.refresh_fx_rates` (dry-run by default,
  `--apply` to write), whose `render/1` clauses are exhaustively matched
  against every error tuple the context function can return.

## Verification

- Traced the "cannot straddle" locking claim against the actual bodies of
  `set_default_currency/1` and `change_base_currency/2`
  (`lib/phoenix_kit_billing.ex`): both call `renormalize_all_rates!/1` as
  their first transactional write, which is
  `from(c in Currency, update: [...]) |> repo().update_all([])` — genuinely
  no `WHERE` clause, so it does touch the current default's row. Confirmed
  the claim is accurate: Postgres will block that `update_all` on this
  function's `FOR UPDATE` lock (or vice versa) rather than let the two
  interleave.
- Checked `parse_fx_rate/1` and `fx_rate_column_precision_error/1` against
  `phoenix_kit_currencies.exchange_rate`'s actual column type
  (`numeric(15,6)`, confirmed in the migration chain) — the `:half_up`
  rounding-then-compare approach correctly mirrors what Postgres itself does
  at cast time, and the test suite's boundary cases
  (`999999999.999999` accepted, `1000000000` rejected, `0.0000001` rejected)
  match the moduledoc's own worked Postgres examples.
- Confirmed `list_currencies/0` (used to build `known_by_code`) has no
  `enabled` filter by default, matching `change_base_currency/2`'s existing
  "a disabled currency's rate is still real data" precedent — a disabled
  currency in the provider's response is validated and written like any
  other, not silently skipped.
- Confirmed `Events.broadcast_currencies_changed/1` only reads `:code` off
  the struct it's given (`lib/phoenix_kit_billing/events.ex:364`), so
  constructing a bare `%Currency{code: code}` for the post-commit
  reconciliation broadcast (rather than the full row) is correct, not a
  shortcut that loses data.
- `announce_committed_fx_rates/1`'s first clause matches on
  `%{updated: updated} = result` — confirmed this correctly falls through to
  the catch-all (no announcement) for a dry-run result, because that map has
  no `:updated` key at all (`%{dry_run: true, would_update:, skipped_base:}`),
  not because of an explicit dry-run check. Slightly implicit, but correct
  and covered by the dry-run test group.
- The mix task's `render/1` clauses were checked one-for-one against every
  tagged error `refresh_rates_from_provider/1` can return — no gap.
- Ran `mix precommit` (format, `compile --warnings-as-errors`,
  `deps.unlock --check-unused`, `hex.audit`, `credo --strict`, dialyzer) and
  `mix test` against real Postgres — see Verification Results below.

## Issues Found

### IMPROVEMENT - MEDIUM: the locking strategy can deadlock against `set_default_currency/1` / `change_base_currency/2` under real concurrency

**File:** `lib/phoenix_kit_billing.ex`, `lock_default_currency_for_update/0`
vs. `renormalize_all_rates!/1`

The moduledoc's "Atomicity" section is correct that the two operations
*cannot silently interleave* — but it doesn't address that they can
**deadlock** each other rather than one cleanly waiting for the other, under
Postgres's actual row-by-row lock acquisition for an unqualified `UPDATE`:

1. Transaction A (`refresh_rates_from_provider`) takes `SELECT ... FOR
   UPDATE` on the default-currency row first.
2. Transaction B (`set_default_currency/1` or `change_base_currency/2`)
   starts its table-wide `update_all` (no `WHERE`). Postgres acquires row
   locks as it scans; if it locks and updates some *other* currency row
   (say `"EUR"`) before it reaches the default row, that first lock
   succeeds — then it blocks trying to lock the row A already holds.
3. If A's own batch happens to include a write to that same `"EUR"` row
   (`write_fx_rate!/2` → `update_currency/2`), A now blocks waiting for the
   lock B is holding on `"EUR"` — while B is blocked waiting for A's lock on
   the default row.

Classic deadlock. Postgres's deadlock detector will resolve it by aborting
one transaction with a `Postgrex.Error` ("deadlock detected"). That
exception is **not** rescued inside `set_default_currency/1` /
`change_base_currency/2`'s transaction bodies (`repo().transaction(fn -> ...
end)` re-raises an unhandled error to the caller per Ecto's own contract),
so the loser of the race crashes its caller with an unhandled exception
rather than returning a tagged error. If `refresh_rates_from_provider/1` is
the loser instead, it's already handled (`write_fx_rate/2` rescues around
`update_currency/2` and turns any raise into `{:error, {:write_failed, ...}}`
before the transaction rolls back) — only the promotion-function side of
this race is unguarded.

This is not silent data corruption — Postgres's own detector guarantees one
side aborts cleanly and the other proceeds correctly — and it requires a
precise, narrow race (an admin promoting/switching the base currency at the
exact moment an fx-rate refresh is touching a different currency's row) that
is plausible but rare given both operations are manual/scheduled admin
actions, not user-facing traffic. **Not fixed here**: closing this properly
means picking a consistent lock-acquisition order across three already
independently-tested, already-shipped functions (this PR's new one plus two
functions from PR #33/#34) — a cross-cutting concurrency-control change that
deserves its own PR and its own concurrency test, not a drive-by edit as
part of reviewing an unrelated feature. Recording it here so it's on record
rather than silently discovered in production.

## Verification Results

- `mix precommit`: PASS (see run output — format, `compile
  --warnings-as-errors`, `deps.unlock --check-unused`, `hex.audit`, `credo
  --strict`, dialyzer all clean).
- `mix test` against real Postgres: PASS (see run output).

## What Was Done Well

- The "refused whole, nothing partial" validation design (classify every
  entry against one snapshot before any write) closes a real correctness
  gap — a naive per-entry loop would leave a batch half-applied on hitting
  the first bad currency code partway through a provider's response map.
- The precision checks (`:rate_too_small`, `:rate_too_large`) were derived by
  testing the actual Postgres column behavior directly (documented in
  comments and mirrored by boundary tests at exactly `999999999.999999` /
  `1000000000` / `0.0000001`), not guessed from the column's declared type —
  the kind of check that's easy to get subtly wrong (off-by-one at the
  rounding boundary) and this suite pins both edges.
- The post-commit re-broadcast is a genuinely subtle fix: it correctly
  identifies that "broadcast during the transaction" (what every other
  writer in this module does) is fine for a *single* writer under normal
  contention, but insufficient once *this* function's write can race a
  subscriber's own read against an as-yet-uncommitted transaction — and it
  fixes this by re-announcing rather than trying to suppress or delay the
  first (necessarily earlier, necessarily sometimes-stale) broadcast.
- Test coverage is unusually direct about proving properties that are hard
  to verify without real concurrency: the "case-insensitive" test asserts
  the events fire an even, deterministic count rather than just eyeballing
  the row value, and the "subscriber reacting to every announcement" test
  explicitly documents which property it *can't* reproduce (a second pooled
  connection under READ COMMITTED) versus which one it's actually pinning
  (count/ordering of announcements).

## Verdict

**Approved.** One concurrency-robustness gap recorded above (not fixed;
narrow, non-corrupting, needs a dedicated cross-function change).
