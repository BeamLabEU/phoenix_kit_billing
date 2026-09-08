# Code Review: PR #32 — Per-domain currency, stage Э1: request-scoped display currency, present/3, Order freeze fields, currency cache

**Reviewed:** 2026-09-06
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/32
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** bc6b8c3e9969682d0577024906c5f66cf0170028
**Status:** Merged

## Summary

Stage Э1 of the per-domain-currency effort:

1. **Request-scoped display currency** — `Currency.put_request_currency/1` /
   `get_request_currency/0` (process-scoped, mirrors
   `PhoenixKit.Languages.put_request_default_language/1`), plus
   `get_base_currency/0`, `get_display_currency/0`, and
   `resolve_display_currency/1` with a documented fail-safe (§6.3): an unusable
   target (unknown/disabled/non-positive rate) falls back to the base and logs
   once per process per offending code.
2. **`Currency.present/3`** — the single conversion entry point going forward,
   with a live path (resolves the target on every call, so a rate edit is
   visible immediately) and a frozen path (`opts[:rate]`, for a cart/order's own
   snapshot rate — deliberately bypasses `resolve_display_currency/1`'s
   fail-safe so a rate frozen before the target was disabled doesn't silently
   get discarded).
3. **`billing_default_currency` setting retired** — every reader now goes
   through the `is_default` row (`get_base_currency/0`) instead; the dead
   "Default Currency" select on the settings page is removed along with it.
4. **Currency cache (§13)** — a `PhoenixKit.Cache` instance (5 min TTL) behind
   `get_base_currency/0` and `get_currency_by_code/1`, invalidated wholesale by
   every currency writer (`create_currency/1`, `update_currency/2`,
   `set_default_currency/1`, `delete_currency/1`).
5. **`Order` schema gains three nullable, currently-unwritten fields** —
   `base_currency`, `exchange_rate`, `base_total` — scaffolding for a later
   stage that will freeze them at order creation.

The request/display-currency resolution logic, the frozen-vs-live distinction
in `present/3`, and the cache are all well-designed and thoroughly tested
(`currency_present_test.exs`, `currency_request_test.exs`,
`display_currency_test.exs`, `currency_query_count_test.exs`). The one issue
below is not a design flaw in any of that — it's a dependency-coordination gap
in item 5 that broke the *existing*, shipped orders feature for every current
installation.

## Issues Found

### 1. [BUG - CRITICAL] `Order`'s three new fields reference DB columns that don't exist on the currently-published core — FIXED
**File:** `lib/phoenix_kit_billing/schemas/order.ex` lines 114-121 (as merged)
**Confidence:** 100/100

`Order`'s moduledoc claimed the three new columns were "Nullable — core V185
backfills these from data, ... a host running an older core simply has them
come back nil; nothing downstream requires them." That's not what actually
happens. Ecto always lists every schema-declared field in its generated
`SELECT`, regardless of whether a query cares about it — so on any host whose
`phoenix_kit` resolves to what is *actually* published on Hex today
(`~> 2.0`, latest `2.15.1`, migration chain only through V183 — the local
`/workspace/phoenix_kit` checkout's V185/V186 that add these exact columns had
not shipped), every single query against `Order` raised:

```
** (Postgrex.Error) ERROR 42703 (undefined_column) column p0.base_currency does not exist
```

Verified directly: `mix test` against this repo's own Postgres (migrated with
the Hex-resolved core, no `PHOENIX_KIT_PATH` override) failed 6 tests —
`Billing.list_orders/1`, `get_order/1`, `delete_order/1`, and the entire
`PhoenixKitBilling.Web.UserOrdersTest` LiveView suite (mount crashes) — every
one of them a query that touches `Order`, i.e. essentially the whole
orders/invoices/user-dashboard surface. `order_fx_fields_test.exs`, the PR's
own new test for these fields, is a pure `ExUnit.Case` changeset test with no
DB access, so it could not have caught this; nothing else in the PR queries an
`Order` row.

**Fix applied:** rather than wait on a core release, `PhoenixKitBilling`
already has an established pattern for exactly this situation —
`PhoenixKitBilling.Migrations` V2 added `rounding_rule`/`rate_updated_at` to
the core-created `phoenix_kit_currencies` table without waiting for core to
ship them. Added **V3** to that same chain: three
`ALTER TABLE phoenix_kit_orders ADD COLUMN IF NOT EXISTS ...` statements, using
the identical column names and types the future core migration
(`phoenix_kit`'s local, unpublished `V186`) already uses — so the day that core
release actually ships, its own `ADD COLUMN IF NOT EXISTS` no-ops on hosts
already at V3, and its backfill (deriving `base_currency`/`exchange_rate` for
pre-existing rows from `phoenix_kit_currencies`) still runs and still does
useful work. V3 adds the columns nullable with **no backfill of its own** —
inventing a derivation here would duplicate logic that belongs to whichever
release actually owns getting it right, and nothing reads these fields yet.

Changes: `lib/phoenix_kit_billing/migrations.ex` (`@current_version` 2 → 3,
moduledoc, `up_statements/2`, `down_statements/2`), `Order`'s field comment
corrected to point at V3 instead of the nonexistent "core V185", and
`test/phoenix_kit_billing/migrations_test.exs` extended with V3 coverage
(new columns' exact DDL, `down` to below V3, and a schema/DDL sync check)
plus updates to the existing `current_version`/marker-stamping/`down`
assertions that hardcoded `2`. Full suite re-run against Postgres:
392 tests, 0 failures. `mix precommit` (format, credo --strict, dialyzer):
clean.

## What Was Done Well

- `resolve_display_currency/1`'s fail-safe (§6.3) is exactly right for a
  storefront: an unknown/disabled/non-positive-rate code degrades to showing
  the correct amount in the wrong-but-safe currency rather than crashing a
  page or showing a bogus price, and the once-per-process-per-code log
  dedup means a busy page doesn't flood the log for one bad code.
- `present/3`'s frozen-rate path is deliberately isolated from
  `resolve_display_currency/1` specifically so a target being disabled
  *after* a cart/order froze its rate can't silently discard that rate — the
  moduledoc cites the exact real bug ("an EUR cart disabled mid-checkout used
  to lose its conversion this way") that motivated the split, and
  `currency_present_test.exs` has a named regression test for precisely that.
- The cache correctly distinguishes "not cached" from "cached as nil" via a
  sentinel, and invalidates the whole namespace (not just one key) on any
  write, because `set_default_currency/1` alone can change every row's rate
  in one call — a narrower per-key invalidation would leave every other
  currency's cached rate stale.
- `CoreCompat`'s call-site list was updated in the same commit as the new
  `PhoenixKit.Cache` calls, per the repo's own convention.
- `currency_query_count_test.exs` measures the actual query count via
  telemetry rather than asserting an implementation detail, and deliberately
  asserts `<= 3` (the plan's bound) rather than the tighter number the cache
  actually achieves, so a future partial regression doesn't fail on an
  overly precise number.

## Verdict

**Approved with fixes.** The request-currency/cache/present design is solid
and well-tested; the one critical issue was a cross-repo dependency
coordination gap (Order columns assumed a core migration that Hex doesn't have
yet), not a flaw in this PR's own logic, and is now fixed independently of
when that core release ships.
