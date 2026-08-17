# Code Review: PR #22 — Fix KeyError on billing print views: :user never preloaded, plus a route parameter mismatch that kept two screens from mounting

**Reviewed:** 2026-08-17
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/22
**Author:** timujinne
**Head SHA:** b036c9f (merged via 56b47c6)
**Status:** Merged

## Summary

Two independent bugs, both `KeyError: key :email not found in:
#Ecto.Association.NotLoaded<...>`-shaped:

1. `InvoicePrint`/`ReceiptPrint` (`preload: [:order, :transactions]`) and
   `CreditNotePrint`/`PaymentConfirmationPrint` (`preload: [:order]`) never
   preloaded `:user`, but their templates read `@invoice.user.email`.
   `InvoiceDetail.Actions.reload_invoice/1` had the same gap after
   `record_payment`/`record_refund`. Fixed by adding `:user` to every
   preload list, including all 8 public `send_*_email` functions in
   `phoenix_kit_billing.ex` whose `ensure_preloaded(invoice, [:order])`
   call was one association short of what it actually reads.
2. `CreditNotePrint`/`PaymentConfirmationPrint`'s `do_mount` pattern-matched
   on `%{"id" => ..., "transaction_uuid" => ...}`, but the registered route
   (`Web.Routes`) binds `:invoice_uuid`, not `:id` — so `do_mount` never
   matched and the LiveViews never mounted. Fixed by matching on
   `invoice_uuid`.

Both fixes are covered: `print_lvs_test.exs` and `invoice_detail_test.exs`
mount the real routes end-to-end; `send_email_preload_test.exs` exercises
all 8 public `send_*_email` functions directly against an
under-preloaded invoice, bypassing every `web/` call site so the assertion
can't pass by accident. The regression tests assert the concrete `:ok`
return value, not just "didn't raise."

## Issues Found

### 1. [BUG - MEDIUM] `Paths.payment_confirmation/2` builds the pre-fix URL shape — FIXED
**File:** `lib/phoenix_kit_billing/paths.ex` line 21-22
**Confidence:** 95/100

Same bug class as this PR's route-param fix, but in the one file the PR
didn't touch. `Web.Routes` registers
`/admin/billing/invoices/:invoice_uuid/payment-confirmation/:transaction_uuid`,
but `Paths.payment_confirmation/2` built
`.../invoices/#{id}/payment/#{txn_uuid}` — missing the `-confirmation`
segment (pre-dates this PR; introduced in 684353b, "Fix provider payment
paths broken by PR #15"). `Paths.credit_note/2` is correct by comparison.

Currently dead code — nothing in `lib/` or `test/` calls
`Paths.payment_confirmation/2` (the one live link, in
`invoice_detail.html.heex`, hand-rolls the URL inline instead) — so it
never 404'd in production. But it's a live trap for the next caller.
Fixed: corrected the segment to `payment-confirmation` and added
`test/phoenix_kit_billing/paths_test.exs` pinning both `Paths.credit_note/2`
and `Paths.payment_confirmation/2` against their route segments.

## What Was Done Well

- Root-caused via the actual template reads (`@invoice.user.email`), not
  just silenced the crash.
- Regression tests mount the real registered routes end-to-end rather than
  stubbing `Billing.get_invoice/2`, so they'd have caught the route-param
  mismatch too, not just the preload gap.
- The email-preload tests deliberately test the public `send_*_email/2,3`
  boundary rather than the private `do_send_*` wrappers, with a documented
  rationale for why the private wrappers don't need separate coverage.
- Test moduledocs explain the *mechanism* (`NotLoaded` struct is truthy,
  so a template guard doesn't shield the `.email` access) rather than just
  restating the symptom.

## Verdict

**Approved with fixes** — the merged PR is correct and well-tested as-is.
One adjacent, same-class bug (`Paths.payment_confirmation/2`) was found and
fixed in this review pass; everything else checked out.
