# Code Review: PR #33 — Per-domain currency, stage Э2: rounding_rule in present/3, currencies_changed event, synchronous cache invalidation

**Reviewed:** 2026-09-07
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/33
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 40836a423942c7dc79dd8b54798ec34fda8ec0e6
**Status:** Merged

## Summary

Stage Э2 of the per-domain-currency effort, on top of Э1 (PR #32):

1. **`rounding_rule` is applied.** `Currency.present/3` now rounds the raw
   converted figure through `round_for_display/3` — `"exact"` (default),
   `"charm_99"` (round down to X.99, never up — computed as
   `floor(raw + 0.01) − 0.01` so it can't cross a whole unit), `"charm_90"`
   (round to nearest X.90), `"integer"` (whole units). Applied identically on
   both the live path and the frozen (`opts[:rate]`) path, on the RAW
   converted amount exactly once, and never on the base currency. A changeset
   validation (`validate_charm_needs_two_decimals/1`) rejects a charm rule on
   a currency whose `decimal_places != 2`.
2. **`{:currencies_changed, code}` PubSub event.** `Events.currencies_topic/0`
   + `subscribe_currencies/0` + `broadcast_currencies_changed/1`, wired into
   all four currency writers (create/update/set_default/delete) via a new
   `maybe_broadcast_currencies_changed/1` pipeline stage.
3. **Synchronous cache invalidation.** `invalidate_currency_cache/0` follows
   its `PhoenixKit.Cache.clear/1` cast with a same-process
   `PhoenixKit.Cache.stats/1` call — a barrier, since Erlang preserves message
   order from one sender to one receiver, so the clear is guaranteed applied
   before the broadcast fires and a subscriber's re-read can never observe the
   stale cache entry.
4. Admin Currencies page gets a "Rounding" column/badge and a rule select on
   the add/edit form; invoice detail's transactions table is migrated to the
   shared `TableDefault`/`TableRowMenu` components (unrelated cleanup, bundled
   in the same PR).

## Verification

- **The cache barrier claim was checked against the actual core
  implementation**, not just the comment: `/workspace/phoenix_kit/lib/phoenix_kit/cache/cache.ex`
  confirms `clear/1` is `GenServer.cast(via_tuple(cache_name), :clear)` and
  `stats/1` is `GenServer.call(via_tuple(cache_name), :stats, 5000)` against
  the *same* `via_tuple` — so the ordering guarantee the moduledoc leans on is
  real, not assumed. `stats/1` also rescues/catches a missing or unavailable
  cache process and returns a default map rather than raising, matching the
  "no extra guard needed" claim.
- `{PhoenixKit.Cache, :stats, 1}` was correctly added to `CoreCompat`'s
  `runtime_calls/0` (unguarded-call) list, matching how it's actually called.
- Ran the project's own gate: `mix precommit` (format, compile
  `--warnings-as-errors`, `credo --strict`, dialyzer) — clean, no findings.
- `mix test` against a real Postgres (`pg_isready` confirmed available this
  session): **455 tests, 0 failures, 4 skipped** (the 4 are the
  pre-existing, documented `subscription_type_uuid` core-migration skips —
  unrelated to this PR).
- Spot-checked the `charm_99`/`charm_90` arithmetic in the new test suite
  (`currency_rounding_rule_test.exs`) by hand against the documented formulas
  — 19.99 → 17.99 (charm_99), 19.99 → 17.90 (charm_90), etc. — all consistent.
- `rounding_rule`/`rate_updated_at` are columns from **billing's own**
  migration chain (`Migrations` V2), not a core-owned table — so, unlike the
  Order-fields issue found in PR #32's review, there's no risk of this PR
  referencing a core migration Hex hasn't shipped yet.

## Issues Found

None. The rounding table, the pipe-order comments, and the cache-barrier
reasoning were all checked against the actual core source rather than taken
on faith, and held up.

## What Was Done Well

- `round_for_display/3` is genuinely "the one table" — both `present_live/3`
  and `present_frozen/4` funnel through it, so catalog display and a frozen
  cart snapshot can never disagree about rounding for the same rate (locked
  in by `"catalog display equals the cart snapshot under charm_99"`).
- `charm_99` rounding down instead of `Decimal.round/2`-then-subtract avoids
  the obvious off-by-one trap (18.985 rounding up to 18.99 instead of down to
  17.99) — there's a dedicated regression test for exactly that.
- The synchronous-barrier trick for cache-then-broadcast avoids reaching for
  heavier machinery (a `Task`, a `Process.sleep`, a second GenServer) for a
  same-process ordering guarantee that Erlang already provides for free.
- `currency_events_test.exs`'s primary test explicitly notes *why* the
  barrier is needed empirically (~1/15 runs would catch a swapped pipe order
  without it) rather than just asserting the happy path.

## Verdict

**Approved, no changes.**
