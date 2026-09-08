# Code Review: PR #40 — Per-domain currency, stage Э5: provider amounts by the currency's decimal places, not a hard-coded 100

**Reviewed:** 2026-09-08
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/40
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 6806b1f (branch `feature/currency-e5-payments`, 4 commits:
81e430d, 6835eb7, 63da18b, 6806b1f)
**Status:** Merged

## Summary

Closes the last hard-coded `× 100` in the currency-aware effort (§2.6/§7,
Э5): every provider converted between a shop-side `Decimal` and a provider's
integer minor unit by multiplying/dividing by a literal `100`, correct only
for two-decimal currencies. A zero-decimal currency (JPY, KRW) sent through
that factor is charged **100×** its intended amount; a three-decimal one
(BHD, KWD) is silently truncated. Introduces:

- **`PhoenixKitBilling.Providers.MinorUnits`** — the single conversion point
  (`to_minor_units/2`, `from_minor_units/2`, `to_minor_units_and_places/2`,
  `decimal_places/1`), reading `decimal_places` per-code from
  `phoenix_kit_currencies`. Refuses (`{:error, :unknown_currency}`) rather
  than guessing a decimal-place count for a code the shop's table has never
  seen, and refuses (`{:error, :fractional_amount}`) rather than silently
  rounding away precision a currency can't represent.
- **`Transaction.currency`** loses its `default: "EUR"` schema literal — the
  field was already in `validate_required/2` since the schema's original
  commit, but the default silently satisfied that check, so a caller that
  forgot to pass `:currency` got a transaction honestly mislabeled EUR
  instead of a validation error. Both known insert paths
  (`build_transaction_attrs/4`, used by both `record_payment/3` and
  `record_refund/3`) already pass `currency: invoice.currency` explicitly,
  so this tightening has no live caller to break.
- All four providers (Stripe, PayPal, Razorpay, EveryPay) converted at every
  outbound (charge/checkout/refund) and inbound (webhook confirmation) site,
  not just the ones exercised by the original bug report — see Verification
  for how this was checked.
- `webhook_processor.ex`'s `webhook_amount/3` reads the currency each
  provider's own normalizer now attaches alongside its amount and converts
  via `MinorUnits.from_minor_units/2`; an unrecognized or absent currency
  falls back to the invoice's own remaining balance (the same fallback this
  function already used for "no amount at all") rather than guessing a
  factor.
- The branch's own history shows a genuine self-caught regression: the first
  commit (81e430d) made Stripe/PayPal currency-aware but left Razorpay's
  four outbound call sites on the old `× 100`, which — combined with the
  *inbound* confirmation becoming currency-aware in the same commit — would
  have both overcharged a non-two-decimal Razorpay currency AND then
  recorded the invoice as paid ~100× its total from the (now-correct)
  webhook read. The final commit (6806b1f) closes exactly that asymmetry
  across all four Razorpay call sites plus two EveryPay precision gaps.

## Verification

- **Confirmed no leftover hard-coded conversion factor remains** anywhere in
  `lib/phoenix_kit_billing/providers/*.ex` — `grep -n "100\b"` across all
  four provider files matches only comments/moduledoc prose describing the
  bug being fixed, none of them live code.
- **Traced the Razorpay self-fix's completeness** directly against the
  final diff: `create_order/1`, `create_order_for_recurring/2`,
  `do_create_refund/3` (now via `build_refund_body/3`), and
  `invoice_to_opts/1` all route through `MinorUnits.to_minor_units/2` (or
  pass a raw `Decimal` through to a function that does) — no site still
  does its own `Decimal.mult(amount, 100)`.
- **Checked `get_currency_by_code/1` (the function every `MinorUnits`
  lookup goes through) upcases its input** (`lib/phoenix_kit_billing.ex`)
  — confirms provider responses that report currency in lowercase (Stripe
  refunds, for one) still resolve correctly rather than silently missing
  the table and refusing.
- **Confirmed `handle_payment_authorized/2`'s missing `:currency` key**
  (Razorpay, an informational-only event) is harmless: `webhook_processor.ex`
  never dispatches `"payment.authorized"` to `calculate_payment_amount/2` —
  only `"checkout.completed"` and `"payment.succeeded"` do, and both of
  those handlers do carry `:currency` alongside their amount.
- **Verified `Transaction.currency`'s tightened `validate_required` has no
  live caller relying on the old default**: grepped every
  `Transaction.changeset/2` call site
  (`build_transaction_attrs/4` at two call sites, `record_payment/3` and
  `record_refund/3` both routing through it) — `currency: invoice.currency`
  is set explicitly at the one place that builds transaction attrs, so
  there is no path where an omitted `:currency` used to silently resolve to
  `"EUR"` and now fails instead.
- **`MinorUnits.to_minor_units_and_places/2`'s exactness claim** (`Decimal`
  scaling by `Integer.pow(10, places)`, integer arithmetic only, never a
  float) checked against `Decimal.integer?/1`'s actual behavior in the
  pinned `decimal` `3.1.1` — confirmed it exists with the expected
  semantics.
- Ran the full gate against the merged tree (this repo's `main`, HEAD at
  merge time): `mix precommit` (format, `compile --warnings-as-errors`,
  `deps.unlock --check-unused`, `hex.audit`, `credo --strict`, dialyzer) —
  clean. `mix test` against real Postgres — **545 tests, 0 failures, 4
  skipped** (same 4 pre-existing, documented core-migration skips).

## Issues Found

None blocking. No new bugs found in the diff itself.

## What Was Done Well

- **The branch caught its own asymmetry before merge.** The final commit's
  message names the exact failure mode a half-applied fix would have
  caused (overcharge outbound, then honestly record ~100× as paid from the
  now-correct inbound read) rather than treating "some call sites fixed" as
  done — this is the review discipline this exact task exists to apply,
  already done by the author.
- **Consistent "refuse, don't guess" posture** across every new code path:
  an unrecognized currency or over-precise amount returns a tagged error
  (`:unknown_currency`, `:fractional_amount`) that callers propagate, never
  a fallback decimal-place count or a silently dropped digit — matches this
  package's existing `currency_required_test.exs` philosophy for the
  provider registry, now extended to the amount-conversion layer.
- **EveryPay's two call sites without a currency (`charge_payment_method/3`,
  `create_refund/3`) were left deliberately unrounded** rather than having a
  currency invented to justify a rounding decision — a smaller, more honest
  fix than reaching for the shop's base currency as a plausible-looking
  guess.
- **PayPal's `minor_units_to_decimal_string/2`** renders a minor-unit
  integer back to a wire-format decimal string by string manipulation
  (pad-then-split), never through a float — avoids exactly the kind of
  precision loss a naive `amount / 100.0` string-formatting approach would
  reintroduce for a large amount.
- Test coverage mirrors the fix's own shape: a shared `MinorUnitsTest` for
  the conversion primitive (zero/two/three-decimal currencies, case
  sensitivity, refusal semantics) plus a dedicated `_currency_amounts_test`
  per provider proving each one's specific call sites actually use it, not
  just that the shared module is individually correct.

## Verdict

**Approved, no changes.**
