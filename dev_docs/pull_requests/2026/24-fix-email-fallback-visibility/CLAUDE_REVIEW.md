# Code Review: PR #24 — Stop reporting :ok when the e-mail module is absent; carry the send result with the invoice

**Reviewed:** 2026-08-18
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/24
**Author:** timujinne
**Head SHA:** 23f298d (merged via 5c0965d)
**Status:** Merged

## Summary

Fixes B003 (email-fallback-visibility) round 2: `send_email_if_available/4`
gated on `Code.ensure_loaded?(PhoenixKit.Modules.Emails)` — the sibling
package's namespace module — then unconditionally `apply/3`'d
`PhoenixKit.Modules.Emails.Templates.send_email/4`, a *different* module
one level down that can be absent even when the namespace module is
present (a partial/stale `phoenix_kit_emails` install). It now checks
`Templates` itself plus `function_exported?/3`, and returns
`{:error, :emails_module_not_installed}` — logged once per BEAM boot via
`:persistent_term` (noise control), but **returned on every single call**
(the actual guarantee).

The real defect this round fixes: that return value used to be discarded
entirely by `do_send_invoice/3` and its three siblings
(`do_send_receipt/2`, `do_send_credit_note/3`,
`do_send_payment_confirmation/3`), which then unconditionally returned
`{:ok, invoice}`. Combined with the once-per-boot log dedup, an install
with `phoenix_kit_emails` permanently absent got a log line for the
*first* invoice sent that boot and **silent, caller-visible "success" for
every one after** — the original B003 defect, reintroduced for 99% of
calls on the one kind of install this contract exists for. Fixed by
carrying the email outcome through as a third tuple element:
`{:ok, invoice, email_result}` (`:skipped` when `:send_email` is false).
Every caller updated: the four `do_send_*` functions, `invoice_detail/actions.ex`'s
4 LiveView handlers (now flash an accurate warning vs. success),
`webhook_processor.ex`'s `send_receipt/1` (logs the email failure
distinctly without failing the webhook), plus moduledoc/`@doc` examples.

Also, opportunistically: the 8 dashboard-stat helpers'
`rescue _ -> 0/Decimal.new(0)` became a logged
`dashboard_stat_fallback/3` (same defect class — a real query failure was
indistinguishable from a healthy, empty system), and `Activity.log/2`'s
two silent `rescue ... -> :ok` clauses were collapsed into one that logs
and returns `{:error, _}` — verified, not assumed, to be currently
unreachable dead code (core's own `PhoenixKit.Activity.log/1` already
rescues internally), with a test proving that by triggering the real
`DBConnection.OwnershipError` path.

## Issues Found

### 1. [BUG - HIGH] "Updated every caller" missed a file it couldn't have seen — FIXED
**File:** `test/phoenix_kit_billing/web/user_orders_test.exs` line 41-42
**Confidence:** 100/100

`Billing.send_invoice/2`'s return shape changed from `{:ok, invoice}` to
`{:ok, invoice, email_result}` in this PR. PR #23 (`customer-orders-dashboard`)
was developed in parallel and added
`test/phoenix_kit_billing/web/user_orders_test.exs`, whose
`fixture_order_chain/1` still matched the old 2-tuple. PR #23 merged
first; when this PR merged second, both landed on `main` with
`mix test` failing 2 tests with `MatchError` — confirmed by running the
suite before fixing. This wasn't a gap in this PR's own diff (it
genuinely updated every caller *that existed on its branch*); it's a
merge-order hazard between two PRs changing overlapping surface in
parallel. Fixed here (rather than solely in #23's review) because this
PR is the one that changed the contract: matched
`{:ok, invoice, :skipped}`.

### 2. [NITPICK] Credo `--strict` failure inherited from PR #23's test file
**File:** `test/phoenix_kit_billing/web/user_orders_test.exs`
**Confidence:** 100/100

Same file, unrelated to this PR's own diff — see PR #23's review for the
fix (aliasing `UserOrders`). Noted here only because it also blocked this
PR's own `mix precommit` gate once both were on `main` together.

## What Was Done Well

- The actual fix is scoped correctly: the record-level update
  (status/history) already committed by the time the email is attempted,
  so its outcome is carried as a third tuple element rather than folded
  into `{:error, _}` (which would misreport a real, committed change as a
  failure) or silently dropped (the original bug). This distinction is
  explained consistently at every one of the 4 call sites it touches.
- Root-caused, not guessed: the moduledoc for
  `send_email_availability_through_send_invoice_test.exs` documents that
  the author's own prior "warn once per boot" log-dedup change (round 2)
  is what reintroduced the discarding defect, and explains precisely how
  — a caller two frames up (`do_send_invoice/3`) was throwing away the
  signal the log dedup assumed was redundant with something else, when it
  wasn't.
- `Templates` vs. `PhoenixKit.Modules.Emails` (namespace vs. leaf module,
  independently loadable) is a genuinely subtle gotcha, and it's pinned
  with a dedicated stub module (`send_email_module_check_test.exs`)
  reproducing a namespace-present-but-`Templates`-absent install rather
  than just asserting the check exists.
- Verified rather than assumed reachability throughout: the
  `Activity.log/2` rescue-clause cleanup is proven currently unreachable
  (with a test showing *why*, by tracing into core's own rescue), while
  the dashboard-stat fallback logging is proven reachable, using the same
  real-`DBConnection.OwnershipError`-via-unowned-`spawn/1` technique for
  both, rather than mocking either failure.
- `webhook_processor.ex`'s `send_receipt/1` correctly treats a failed
  email as a warning-worthy but non-fatal outcome — the receipt itself
  already saved, so the webhook must not fail over it — while still
  surfacing the distinction in the log instead of swallowing it into the
  generic `:ok` branch.
- The regression test for the round-2 defect
  (`send_email_availability_through_send_invoice_test.exs`) specifically
  asserts on the *return value inside the loop* across two consecutive
  calls, not just a post-hoc log line count — exactly the shape of check
  that would have looked identical whether the fix was real or only
  fixed the first call.

## Verdict

**Approved with fixes.** The core fix is correct, well-reasoned, and
unusually rigorously tested (real failure injection over mocking,
explicit confirmed-red-before-green notes, reachability proven rather
than assumed). The one real issue was a cross-PR merge-order hazard, not
a defect in this PR's own logic — fixed here since this is the PR that
changed the contract. `mix precommit` and the full `mix test` suite
(337 tests, 0 failures, 4 pre-existing skips) are green as of this
review.
