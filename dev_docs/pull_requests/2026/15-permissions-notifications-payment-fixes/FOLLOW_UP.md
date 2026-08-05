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

## Parity work not done in this pass

- Activity logging exists on admin mutations but not on their ERROR
  branches (the `log_failed/3` pattern ecommerce now uses).
- No AGENTS.md section yet for the sub-permissions and notification types
  added here — ecommerce's is the template.
