# PR draft — Split billing permissions, add notifications, fix provider payments

**Base:** `BeamLabEU/phoenix_kit_billing` `main` ← **Head:** `mdon:main`
**Commits:** 6 · **286 tests, 0 failures** · `mix precommit` exit 0

> ⚠️ **Depends on core PR (V162)** — `payment_option_uuid` on
> `phoenix_kit_orders`. Merge and release core first, then bump the pin
> here. The code guards the column's absence, so it degrades rather than
> crashes on an older core.

---

## Summary

Brought billing to the same footing as the e-commerce wave — sub-permissions,
notifications, a first-class payment-option link — and, along the way, an
adversarial money review found that **provider-driven payments were never
being recorded at all**.

## The payment bug

`Transaction` requires `user_uuid`. A webhook- or worker-driven payment
carries no admin actor, so `extract_user_uuid(nil)` returned nil and the
insert failed on **every** provider-confirmed payment: the customer was
charged at Stripe/PayPal/EveryPay, the invoice stayed unpaid with
`paid_amount` 0, and no ledger row existed to reconcile against. An
operator's only recourse was to re-collect or hand-mark the invoice paid.

Those payments are now attributed to the invoice's own user (an
admin-recorded payment still belongs to the admin), and
`provider_transaction_id` / `provider_data` — which every caller already
passed and the code silently dropped — are carried through, so a later
refund webhook can be matched to the charge it reverses.

Two more money defects fixed:
- `record_payment/3` checked only that the amount was positive, so an
  invoice could be paid past its total (the admin UI already rendered an
  `:exceeds_remaining` error the context never returned)
- `mark_invoice_paid/1` set the status and wrote a receipt claiming the
  full total while leaving `paid_amount` untouched: PAID on screen, nothing
  received in the ledger

## Permissions

Four sub-permissions — `manage_orders`, `manage_invoices`,
`manage_subscriptions`, `manage_settings` — with tabs carrying their key
and 32 mutating handlers re-checking through the new `Web.Authz`. The four
printable views (invoice, receipt, credit note, payment confirmation)
guard on mount: they render a customer's paperwork and the route only
required the base key. The `/dashboard` billing-profile pages were checked
and left as they are — they scope by ownership, which is an invariant, not
UI policy.

⚠️ **Breaking on upgrade:** core auto-grants new sub-permissions to the
Admin system role only, so a CUSTOM role holding base `"billing"` keeps
its reads but loses mutations until an operator re-grants.

## Notifications

Admin `invoices` and customer `your_billing` sub-types, kept separate so
an operator muting the invoice firehose does not silence their own
receipts. Recipients union permission holders with **Owner-role holders
and `"*"` superadmins** (neither has permission rows). Copy carries an
invoice number and an amount, never a customer name or address, because
notifications route onward to email and Telegram. `payment_failed` is
admin-only — the customer already saw the decline.

⚠️ Audit action strings stay distinct from notify actions; a test scans
every `Activity.log` call in the module and fails on a collision, because
core auto-derives notifications from registered actions.

## Also here

- `Order.payment_option_uuid` (core V162): the operator-configured option
  the customer chose, distinct from `payment_method`'s closed vocabulary
- `billing_snapshot_policy`: `pending_only` (default — refresh while
  draft/pending, freeze once money has changed hands), `never`, or
  `always`. Previously every later order update re-snapshotted from the
  live profile, so editing a billing profile rewrote the address a
  historical order claimed to have been billed to

## Not fixed here — see FOLLOW_UP.md

Eight further verified findings need a provider sandbox or a
payload-semantics decision: cumulative refund amounts recorded as
per-refund (Stripe/EveryPay), Stripe Checkout undercharging by tax,
EveryPay failing schema validation, unrounded `Decimal.to_integer` in
PayPal/Razorpay, a webhook idempotency race, and three smaller ones.

## Verification

- `mix precommit` exit 0 · 286 tests, 0 failures (Hex pin **and**
  `PHOENIX_KIT_PATH=../phoenix_kit`)
- New: 5 provider-payment regressions, 9 authz/notification contract tests

## Test plan

- [x] 286 tests, 0 failures (both dep resolutions)
- [x] format / credo --strict / dialyzer
- [x] Denied-scope tests that fail if a gate is removed
- [x] Payment attribution + provider-id carrying pinned by regressions
