# PR #64 — Add start_order_payment/2: open an order's invoice and checkout session in one call

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/64
**Author:** timujinne
**Head SHA:** `8cf8c3c`
**Status:** Merged; two findings fixed, one noted

## Summary

Independent of `CODEX_REVIEW.md`. The advisory lock, polling without holding a pool
connection, and the refusal inside a transaction are all well reasoned. Two problems
remained, one of which charges the wrong money.

## Issues Found

### BUG - HIGH — An order could be paid in full for the old total — fixed

`find_or_create_invoice/1` reused any open invoice without comparing it to the order,
while `update_order/2` can change a `draft` or `pending` order that already has an
open invoice, and a settled invoice settles its order without comparing amounts.
Reproduced through the real path:

    start_order_payment(order)              # invoice for 25.00
    update_order(order, total: "100.00")
    start_order_payment(order)              # same invoice reused, buyer charged 25.00
    => invoice paid, order status "paid", order total 100.00

The start now refuses with `{:error, :invoice_out_of_date}` when the open invoice
differs from the order in total or currency, before anything reaches the provider.
Voiding the old invoice lets the next start create a correct one. `Decimal.eq?/2` is
used so `25.0` and `25.00` are the same total. Failing closed is the smallest safe
change. ecommerce's generic branch handles the new reason as `:payment_start_failed`.

**Open decision.** This closes the online path only. An admin can still edit an order
and then record payment on its old invoice, and refusing a total change while an
invoice is open would close both. That is a product rule, so it is left to the
maintainer. One existing test forged an invoice into USD under a EUR order to set up a
stale session; it now moves both, keeping what it checks.

### BUG - MEDIUM — The session context write could wipe the void trail — fixed

`record_checkout_context/3` read the invoice without a lock and wrote back the whole
`metadata`. `metadata["void"]` holds the void reason and the charges still to be
refunded (#65), so a void committed between the read and the write lost them. The
context now merges on the row taken `FOR UPDATE`, as `record_checkout_session/3`
already does. `order_payment_race_test.exs` holds a void open on a second connection;
with the lock removed it fails with the void reason `nil`.

### NITPICK — Some refusals have no `Errors.message/1` clause — not fixed

`:lock_timeout`, `:in_transaction`, `:order_not_found` and `:nothing_to_pay` fall
through to "Unexpected error: ...". No buyer sees that, because ecommerce collapses
every failure into `:payment_start_failed`. Worth adding if a page ever shows them.

## What Was Done Well

- A waiter holds no pool connection, and the moduledoc states the session-pooling requirement.
- Session reuse keys on amount, currency, return URLs and recipient.

## Verdict

Good structure. Both bugs fixed; one product decision open.
