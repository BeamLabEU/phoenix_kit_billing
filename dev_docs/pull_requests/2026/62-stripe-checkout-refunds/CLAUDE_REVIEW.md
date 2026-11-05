# PR #62 — Apply Stripe Checkout refunds from charge.refunded

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/62
**Author:** timujinne
**Head SHA:** `14c8954`
**Status:** Merged; no new findings

## Summary

Independent of `CODEX_REVIEW.md`, read against the current processor. Treating
`amount_refunded` as a running total and booking only what the ledger lacks is the
right model for Stripe's cumulative field, and reading the ledger under the invoice
lock closes the double-booking race.

## Issues Found

None new. Three things were checked because each would have been silent:

- **Lowercase currency.** Stripe sends `usd`. `from_minor_units/2` reaches
  `get_currency_by_code/1`, which upcases, so a refund is not failed as unknown.
- **The provider boundary.** Payment matching requires `payment_method == provider`.
  A renewal records `pm.provider` and a webhook payment records the event's provider,
  so saved-card renewals still match their refunds.
- **Provider type.** `process_event/1` stringifies it before the Ecto comparison.

## Retained limits

As Codex records: non-Stripe payments mislabelled by the old default need correcting
before their refunds match, and a host refund with no payment reference counts toward
any payment of that method on the invoice. A refund recorded as `"bank"` after creating
it at Stripe is booked again by the webhook; that is documented on `record_refund/3`.

## Verdict

Sound.
