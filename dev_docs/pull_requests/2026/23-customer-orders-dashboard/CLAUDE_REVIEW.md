# Code Review: PR #23 — Provide the My Orders dashboard surface instead of advertising a route the module does not own

**Reviewed:** 2026-08-18
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/23
**Author:** timujinne
**Head SHA:** 302076d (merged via e09419a)
**Status:** Merged

## Summary

`user_dashboard_tabs/0` registered a `:dashboard_orders` tab with no
`:live_view`, so the generic tab→route mechanism silently produced no
route at all — `Paths.user_orders()` pointed customers at a 404
(`/dashboard/orders`). This PR:

1. Adds `PhoenixKitBilling.Web.UserOrders`, a real customer-facing,
   read-only LiveView listing the current user's orders, each with its
   invoices (accordion) and each invoice's transactions.
2. Wires it up via `:dashboard_orders`'s new `:live_view` field, and moves
   the path to `billing-orders` — `/dashboard/orders` is hardcoded in
   core (`phoenix_kit/lib/phoenix_kit_web/integration.ex`) for
   `phoenix_kit_ecommerce`'s own orders screen; reusing it here would
   collide with or shadow that module on a host with both installed.
   Verified directly against core's source, not just asserted.
3. Adds `list_user_orders/3`'s opt-in `:preload` option (default `[]`,
   so no existing caller is affected) so the new LiveView can load
   `invoices: :transactions` in one query.
4. Uses core's gettext-backed `PhoenixKit.Utils.Date.short_month/1` for
   locale-aware date formatting (customer-facing, unlike the admin
   screens' locale-blind `Calendar.strftime/2` pattern, which is left
   alone as a documented pre-existing, out-of-scope gap), and adds it to
   `CoreCompat`'s guarded call list.

## Issues Found

### 1. [BUG - HIGH] Cross-PR integration break: `user_orders_test.exs` still used the pre-#24 2-tuple `send_invoice/2` contract — FIXED
**File:** `test/phoenix_kit_billing/web/user_orders_test.exs` line 41-42
**Confidence:** 100/100

This PR's `fixture_order_chain/1` helper was written against `main` before
PR #24 (`fix-email-fallback-visibility`) changed `Billing.send_invoice/2`
to return `{:ok, invoice, email_result}` instead of `{:ok, invoice}`. The
two PRs were developed in parallel and PR #24 merged second, so it could
not "update every caller" — it never saw this file. Once both were on
`main`, `mix test` failed with 2 `MatchError`s in this file (confirmed by
running the suite before fixing). Fixed by matching
`{:ok, invoice, :skipped}`. Full root-cause and fix also recorded in PR
#24's own review, since the contract change is what broke this call site.

### 2. [NITPICK] `mix credo --strict` failure in the new test file — FIXED
**File:** `test/phoenix_kit_billing/web/user_orders_test.exs`
**Confidence:** 100/100

Three `Credo.Check.Design.AliasUsage` violations (fully-qualified
`PhoenixKitBilling.Web.UserOrders.localized_date/1` calls instead of an
aliased `UserOrders.localized_date/1`) made `mix precommit` exit non-zero
at the `credo --strict` step, before `dialyzer` even ran. Fixed by adding
`alias PhoenixKitBilling.Web.UserOrders` and using the short form.

### 3. [NITPICK] `Paths.dashboard_root/0` is unused
**File:** `lib/phoenix_kit_billing/paths.ex` line 48
**Confidence:** 85/100

Added as "a safe fallback target when a more specific customer route
isn't guaranteed to exist yet", but nothing in `lib/` or `test/` calls it
— `UserOrders.mount/3`'s own error paths push to
`Routes.path("/dashboard")` directly instead. Not wrong, just currently
dead code. Left as-is — plausible near-term use (the exact fallback
`UserBillingProfiles`'s error branches could adopt), not worth removing
over in a review pass.

### 4. [OBSERVATION] `UserOrders.mount/3` queries the database directly in `mount/3`
**File:** `lib/phoenix_kit_billing/web/user_orders.ex` line 131-158
**Confidence:** 70/100

`mount/3` runs twice per navigation (disconnected HTTP render, then again
over the LiveView socket), so `Billing.list_user_orders/3` here executes
twice per page view rather than once. This screen has no
`handle_params/3` to move the load into. Not flagging as a bug to fix,
though: it's the exact same shape already used by the sibling
`UserBillingProfiles` LiveView (`lib/phoenix_kit_billing/web/user_billing_profile_form.ex`'s
neighbor, `user_billing_profiles.ex`) — this PR followed an existing,
established convention in this codebase rather than introducing a new
one. Worth a follow-up across both screens together, not scoped to this
PR alone.

## What Was Done Well

- The route-collision reasoning (`/dashboard/orders` reserved for
  `phoenix_kit_ecommerce`) was verified against core's actual source
  (`integration.ex`'s hardcoded `live "/dashboard/orders", ...` in two
  `authenticated_live_*routes/0` blocks), not just asserted from memory of
  how core "probably" works.
- `list_user_orders/3`'s new `:preload` option defaults to `[]`, so
  existing callers (including the admin `Orders` list) are provably
  unaffected — confirmed no other call site needed updating.
- Regression test for the `:preload` option documents having been
  confirmed red (`Ecto.Association.NotLoaded`) against a version with the
  preload dropped.
- Cross-user isolation is tested two ways: HTML string absence AND a
  direct query-result assertion by uuid, which a subtler scoping bug
  couldn't slip past by coincidence.
- `localized_date/1`'s locale/word-order logic is unit-tested directly via
  `Gettext.put_locale/2` against all three supported locales, working
  around the test router only mirroring `/en/...`.
- `short_month/1` was correctly added to `CoreCompat`'s *unguarded* call
  list (it's called directly, not behind `Code.ensure_loaded?/1`), keeping
  the core-API-contract tests honest.

## Verdict

**Approved with fixes.** The substance — the new LiveView, the route
rename, the preload option, the locale-aware dates — is correct and
unusually well-verified against ground truth (core's source, confirmed
red/green tests). The two issues found were both mechanical
gate-breakers (a cross-PR test-contract mismatch and a credo nit), not
design problems, and both are fixed. `mix precommit` and the full
`mix test` suite (337 tests, 0 failures, 4 pre-existing skips) are green
as of this review.
