# Code Review: PR #34 — Per-domain currency, stage Э3: exchange-rate age (rate_updated_at, staleness threshold, admin warning)

**Reviewed:** 2026-09-07
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/34
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 87e46fa759923c7386400207dfbf2ecf4332be47
**Status:** Merged

## Summary

Stage Э3 of the per-domain-currency effort, on top of Э2 (PR #33):

1. **`rate_updated_at` stamping.** `stamp_rate_change/2` dates a currency's
   rate on insert unconditionally (a fresh row's rate was "set right now" by
   definition — `fetch_change/2` alone would miss the case where a caller
   explicitly passes the schema's own default `"1.0"`, which the bulk import
   and the add-currency form both do) and on update only when
   `exchange_rate` is actually in the changeset's recorded changes (so a
   symbol/sort-order-only edit doesn't fake a rate refresh). `rate_updated_at`
   was removed from the changeset's `cast/2` allowlist — the stamping helper
   is the only writer, so a caller passing `rate_updated_at` in `attrs` is
   silently ignored (verified by a dedicated test).
2. **`Currency.stale?/2`** — a currency is stale once
   `DateTime.diff(now, rate_updated_at, :second) > max_age_days * 86_400`.
   Deliberately compares in seconds rather than `DateTime.diff(..., :day)`,
   which truncates rather than rounds and would silently turn a 30-day
   threshold into an effective 31 days; a boundary test suite pins the
   exact-second edge in both directions. The base currency is never stale
   (rate is pinned to 1.0 by definition); a `nil` `rate_updated_at` (a row
   from before this column existed) reads as unknown-age, not stale.
3. **`fx_rate_max_age_days/0`** — a `Settings`-backed threshold (default 30,
   garbage or `<= 0` also reads as 30) read through `Settings`'s own cache,
   deliberately *not* through the currency cache (`with_currency_cache/2`) —
   an admin editing the threshold has no reason to touch a currency row, so
   piggybacking on that cache could leave the threshold stale indefinitely.
4. **`present/3`'s live path warns, once per process per code**, via a
   process-dictionary memo (`maybe_warn_stale/1`) that stores the computed
   staleness *verdict*, not just an "already warned" flag — so a hot catalog
   page pays the `Settings` + `stale?/2` cost exactly once per code per
   process, not once per `present/3` call. A stale rate still converts; this
   only logs. The frozen path never calls it (a cart's frozen rate has no
   meaningful "age").
5. **Admin Currencies page** gets a dismissal-free warning banner naming every
   stale code, an "Updated" column (`<.time_ago>`), and a per-row "out of
   date" badge.
6. **`change_base_currency/2`** — new public function, an explicit "operation"
   (not a settings toggle) for switching the shop's base currency. Billing
   owns steps 1 (renormalize every rate against the new base, dividing by its
   pre-operation rate) and 5 (promote, pinning the new base to exactly 1.0);
   steps 2–4 (recomputing catalog/shipping prices) are injected by the caller
   as `opts[:reprice]`, a 3-arity callback run *inside* the same transaction,
   strictly after renormalization (so it sees the already-renormalized table)
   and strictly before promotion (so an `{:error, _}` from it rolls back the
   renormalization too — catalog and currency table can never disagree about
   which currency is base). Requires an explicit `opts[:catalog_size]`
   (missing → `:catalog_size_unknown`, negative → `:invalid_catalog_size`,
   `> 0` with no `:reprice` → `:reprice_required`) so a silent shop-wide
   re-pricing can't happen by omission. Shares `renormalize_all_rates!/1` and
   `promote_to_base!/3` with `set_default_currency/1`, refactored out in this
   same PR so a future fix to one path can't miss the other.

## Verification

- Ran `mix precommit` (format, compile `--warnings-as-errors`,
  `credo --strict`, dialyzer) — clean.
- `mix test` against real Postgres — **455 tests, 0 failures, 4 skipped**
  (same 4 pre-existing, documented core-migration skips as before; none of
  them touch this PR's surface).
- Traced `change_base_currency/2`'s cache/broadcast call:
  `{:ok, result.promoted} |> maybe_invalidate_currency_cache() |> maybe_broadcast_currencies_changed()`
  is evaluated purely for its side effects and the result discarded, with the
  function separately returning `{:ok, %{old_base:, rate:}}` — confirmed this
  isn't a bug: `result.promoted` (from `promote_to_base!/3`, an unwrapped
  `%Currency{}`) correctly matches `maybe_broadcast_currencies_changed/1`'s
  `{:ok, %Currency{}}` clause, so the cache is genuinely cleared and the
  newly-promoted base's own code is genuinely broadcast before the function
  returns. `mix credo --strict` raised nothing about the discarded pipe
  result either. See Nitpick below.
- Checked `renormalize_all_rates!/1`'s SQL (`round(rate / base_rate, 6)`
  applied to every row, no `enabled` filter) against the test suite's
  Postgres-verified expected values (`select round(1.0/0.909091, 6)` etc.,
  computed by the test author directly against Postgres rather than by hand)
  — consistent, and correctly renormalizes the *old* base's row too (was
  1.0, becomes the reciprocal of the new base's pre-operation rate), which is
  what makes cross-currency ratios come out unchanged.
- Confirmed `do_change_base_currency/2` reads the current default via
  `get_default_currency/0` (a direct, uncached `repo().one()`), not the
  cached `get_base_currency/0` — so there's no risk of the transaction acting
  on a stale cached "old base" row.
- `rate_updated_at` is a **billing-owned** migration column (`Migrations` V2,
  confirmed in `migrations.ex`), not one this PR assumes exists on an
  unpublished core release — the failure mode that made PR #32's Order-field
  issue critical doesn't apply here.

## Issues Found

None blocking. One style nitpick, not fixed (see reasoning):

### Nitpick: discarded pipe result in `change_base_currency/2`
**File:** `lib/phoenix_kit_billing.ex`, `change_base_currency/2` (the
`with ... do` block)

```elixir
{:ok, result.promoted}
|> maybe_invalidate_currency_cache()
|> maybe_broadcast_currencies_changed()

{:ok, %{old_base: result.old_base, rate: result.rate}}
```

The piped expression's return value is never bound or used — it's invoked
purely to trigger the cache-clear/broadcast side effects, then the function
returns a differently-shaped value on the next line. This is correct (see
Verification above) and `credo --strict` has no complaint, but a future
reader skimming the pipe could plausibly mistake it for dead code and delete
it. Not fixed: it's cosmetic, already covered by two dedicated tests
(`"a successful base change broadcasts once, naming the new base"` and the
cache-invalidation path exercised throughout `change_base_currency_test.exs`),
and a bug-fix task shouldn't restyle correct, tested code. Worth a one-line
`_ = ...` or a short comment if this file is touched again.

## What Was Done Well

- `stale?/2`'s seconds-vs-days comparison, with a dedicated boundary test
  suite (`@max_age_seconds`, exact/±1 second) — the kind of off-by-one that's
  easy to get wrong silently and hard to notice in production (a threshold
  that's quietly a day looser than configured).
- `stamp_rate_change/2`'s insert-vs-update split closes a real gap: naively
  relying on `fetch_change/2` alone would silently skip stamping the two most
  common creation paths (bulk import, the pre-filled add form) precisely
  because they pass the schema's own default value.
- `change_base_currency/2`'s transactional handoff to `opts[:reprice]` is
  carefully sequenced and *tested* for the sequencing, not just the happy
  path: `":reprice" describe block` proves the callback runs after
  renormalization (by reading `USD`'s already-renormalized rate from inside
  the callback, on the same connection) and that an `{:error, _}` from it
  rolls back the renormalization byte-for-byte.
- `catalog_size` as a mandatory, explicit argument (rather than an implicit
  "no reprice given means empty catalog" default) makes a silent
  shop-wide re-pricing structurally hard to trigger by omission.
- The staleness memo distinguishes "verdict" from "already warned" so the
  admin threshold-check cost is paid once per code per process rather than
  once per `present/3` call, without smuggling a `Settings`-backed value into
  a cache that's invalidated on the wrong triggers.

## Verdict

**Approved, no changes.**
