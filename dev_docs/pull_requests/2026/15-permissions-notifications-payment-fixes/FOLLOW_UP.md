# Follow-up: billing permissions/notifications wave + payment fixes

Findings from an adversarial money review (2026-08-05) that were VERIFIED
but deliberately not fixed in this pass, because each needs a provider
sandbox or a payload-semantics decision I should not make unilaterally.
Ordered by severity.

## Provider payload semantics

### 1. HIGH — Stripe/EveryPay refunds are recorded CUMULATIVELY

`providers/stripe.ex` reads `object["amount_refunded"]`, which Stripe
defines as the running total for the charge, and EveryPay sums its whole
`refunds[]` array — but `webhook_processor.ex` applies the value as if it
were THIS refund. Two partial refunds of €30 then €20 record €30 + €50 =
€80 against a €50 actual. `paid_amount` drops too far; the invoice can be
voided while the provider still holds money.

PayPal's payload already carries the per-refund amount, so the fix is
per-provider: subtract the already-recorded refunds for that charge (which
`find_transaction_by_provider_id/1` can now find, since this PR carries
`provider_transaction_id`), or read the per-event amount where the
provider offers one.

Needs a sandbox to confirm each provider's field semantics before
changing money math.

### 2. HIGH — Stripe Checkout undercharges by tax

`build_line_items/1` sends only `unit_price × quantity` per line. An
invoice with €100 subtotal + €20 tax opens a Stripe session for €100. The
customer completes checkout believing they have paid; the invoice is short
by the tax and stays unpaid.

Fix is either a tax line item or Stripe's `automatic_tax`/`tax_rates` — a
product decision (who is the tax authority of record, us or Stripe?).

### 3. MEDIUM — EveryPay payments cannot be recorded at all

`Transaction`'s `payment_method` inclusion list is
`bank|stripe|paypal|razorpay`. The EveryPay webhook passes `"everypay"`,
so the changeset fails validation even now that the user attribution is
fixed. Adding the value is trivial; it is listed here because it means
EveryPay has never had a working payment path and that deserves an
explicit decision (support it, or remove the provider).

### 4. MEDIUM — `Decimal.to_integer/1` without rounding in PayPal/Razorpay

`providers/paypal.ex` and `razorpay.ex` convert amounts with
`Decimal.to_integer/1` after multiplying by 100. Any amount with more than
two decimal places raises `cannot convert Decimal without losing
precision` and kills the charge. Stripe rounds first; the other two should
too.

### 5. MEDIUM — Webhook idempotency has a race

`webhook_processor.ex` checks `processed == false` and then processes, with
no unique constraint or lock in between, so two concurrent deliveries of
the same provider event can both proceed. Wants a unique index on
`(provider, event_id)` plus an upsert-or-skip, rather than a read-then-act.

### 6. MEDIUM — The webhook success branch binds a transaction as an invoice

After a payment is recorded, `record_payment/3` returns
`{:ok, %Transaction{}}`, but the caller pattern-matches it as an invoice
and tests `updated_invoice.status == "paid"` — never true, so the receipt
is never generated on the webhook path.

### 7. LOW — Subscription renewals ignore tax

`workers/subscription_renewal_worker.ex` bills the plan price with no tax
line, regardless of the module's tax settings.

### 8. LOW — `fully_refunded?` compares refunds to `invoice.total`

`web/invoice_detail/helpers.ex` uses the total, while the void path uses
`paid_amount == 0`. An invoice paid €40 of €100 and refunded €40 is voided
by one rule and shown as not-fully-refunded by the other.

## Subscription and invoice lifecycle (a later sweep, 2026-08-05)

A second adversarial sweep focused on subscriptions and the invoice
lifecycle — areas this PR does not touch — and found 19 items. Two were
this PR's own and are FIXED here (the subscription form's
pause/resume/cancel/extend handlers were the one lifecycle group the authz
sweep missed; and the new overpay cap read the balance outside the
transaction, so two overlapping payments could both pass — now re-checked
on a locked invoice row).

The rest are pre-existing and want their own PR. Highest severity first:

1. **`cancel_at_period_end` never flips status to `cancelled`** — the flag
   is set but nothing reconciles it when the period ends, so a cancelled
   subscription keeps renewing.
2. **Dunning charges the card with no invoice and no ledger row** — money
   taken with nothing to reconcile it against.
3. **"Resume" after cancel-at-period-end does not clear the flag** — the
   subscription resumes and then cancels anyway at period end.
4. **Trial math delays the first charge by a full billing period** — a
   14-day trial on a monthly plan bills at day 44.
5. **No status-transition guards** — `resume` on a `cancelled` row
   resurrects it with no payment; `pause` works on `cancelled`/`past_due`.
6. **Order "mark paid" does not pay (or create) invoices**, and
   **multiple invoices per order each carry the full total**.
7. Renewal bills the LIVE plan price rather than the subscription's
   snapshot, never sets `subscription_uuid` on the invoice, and a failed
   renewal leaves an orphan `sent` invoice that dunning ignores.
8. Invoice/receipt numbering is `count + 1` with no serialization —
   collisions under concurrency.
9. `void_invoice` is allowed on a `sent`/`overdue` invoice that already has
   `paid_amount > 0`; partial refunds leave `status: "paid"` with a balance
   due, while full refunds void.

## Cross-module integration sweep (2026-08-05)

Verified clean: the V161 migration runs whether or not billing is
installed (both tables belong to core's chain); ecommerce's runtime-marker
guard degrades correctly on a host below V161; no key collisions between
the two modules or against core (permission keys, notification types,
action strings, settings prefixes); and no audit action collides with a
registered notify action in either module.

One LOW finding left open:

- **Billing's schema casts `payment_option_uuid` unconditionally.** Today
  only ecommerce writes it, and it gates on the migration version — but the
  guard therefore lives in the CONSUMER. A future billing-internal caller
  (an admin order form, a context function) passing the key against an
  un-migrated host would hit the missing column. Worth pushing the guard
  down into billing so the contract is not owned by one consumer. Moot once
  the pin floors on the release containing V161.

## Parity work not done in this pass

- Activity logging exists on admin mutations but not on their ERROR
  branches (the `log_failed/3` pattern ecommerce now uses).
- No AGENTS.md section yet for the sub-permissions and notification types
  added here — ecommerce's is the template.
