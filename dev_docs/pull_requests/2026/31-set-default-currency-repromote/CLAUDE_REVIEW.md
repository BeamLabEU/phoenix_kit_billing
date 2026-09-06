# Code Review: PR #31 — Fix set_default_currency/1: re-promoting the current default lost is_default

**Reviewed:** 2026-09-06
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/31
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** f769a5717991e84edd80cfa6771867c3f89be39b
**Status:** Merged

## Summary

Fixes a regression in `set_default_currency/1` (introduced by PR #30's base-rate
invariant): re-promoting the currency that is *already* the default (e.g. a
one-off rate renormalization that doesn't change which currency is base) left
the table with **no default currency at all**.

Root cause: step 2 (`update_all(set: [is_default: false])`, scoped to
`where(is_default: true)`) demotes the target's own row in the database, but the
caller's in-memory `%Currency{}` struct still reads `is_default: true` from
before the call. `Ecto.Changeset.cast/3` diffs the new value against the
struct's *own* current field, sees `true -> true`, and drops `:is_default` from
`changes` — so the promoting `UPDATE` in step 3 never touches that column, and
the row stays `false`.

The fix reloads the row fresh (`repo().get_by!/2`) both before step 1 (re-checks
the base-rate guard against the live row, closing a TOCTOU window against a
stale caller struct) and again before step 3 (building the promote changeset off
current data), then forces `:is_default` and `:exchange_rate` into the
changeset with `Ecto.Changeset.force_change/3` regardless of what the reloaded
row already shows — belt-and-braces against the exact "sees no change" trap
that caused the bug.

## Issues Found

None. The fix is correct, minimal, and the new regression test
(`currencies_base_rate_test.exs`) reproduces the exact repromotion scenario
(re-promoting the current default) and asserts the invariant it protects:
exactly one default row afterward, pinned at `1.0`, with every other rate
correctly renormalized against it.

## What Was Done Well

- The moduledoc addition explains *why* `force_change/3` is necessary (Ecto
  changesets diff against the struct's own field, not a fresh read) rather than
  just what the code does — this is exactly the kind of gotcha that would
  otherwise get "simplified" away by a future editor who doesn't know the
  history.
- The additional guard re-check against the freshly-reloaded row (rather than
  trusting the guard already evaluated against the caller's struct) closes a
  real, if narrow, concurrent-write race: the base rate could have gone invalid
  between the caller reading `currency` and the transaction actually starting.
- Test data covers the full renormalization side-effect (EUR/GBP rates), not
  just the promoted row, so a regression that only fixed the promoted currency's
  own `is_default` while leaving normalization broken would still be caught.

## Verdict

**Approved.** No changes requested.
