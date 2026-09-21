# Code Review: PR #43 — Guest payers, a durable invoice-paid hook for other modules, and EveryPay payments that record

**Reviewed:** 2026-09-21
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/43
**Author:** mdon (Dmitri Don)
**Head SHA:** 8648488
**Status:** Merged (fb697da)

## Summary

Three changes:

1. **EveryPay payments record.** `Transaction`'s `@payment_methods` whitelist
   gains `"everypay"`; a conformance test pins it to `Providers.all_providers/0`.
2. **Guest payers (migration V5).** `phoenix_kit_invoices.user_uuid` and
   `phoenix_kit_transactions.user_uuid` drop `NOT NULL`; a
   `phoenix_kit_invoices_payer_check` CHECK (and a matching `validate_payer/1`)
   requires a user or a non-blank `billing_details->>'email'`. Mail recipients,
   email template variables, the invoice list and the invoice detail fall back
   to the billing email. `down/1` refuses below V5 while guest rows exist.
3. **`InvoiceEvents`.** `:paid`, `:refunded` and `:voided` are enqueued as one
   `InvoiceEventWorker` Oban job per registered handler, inside the transaction
   that changed the invoice. Handlers come from host config plus PhoenixKit
   modules exporting `billing_invoice_event_handlers/0`. `record_payment/3` now
   broadcasts `{:invoice_paid, _}` (it never did) and moves its PubSub after
   commit.

The design is sound: transactional enqueue, per-handler jobs, re-reading the
invoice at delivery, and resolving the job's handler name against the *current*
registry rather than `String.to_existing_atom` are all right. Baseline suite:
607 tests, 0 failures, 4 known skips.

## Issues Found

### BUG - MEDIUM — Handler discovery scanned beam files on disk inside the payment transaction — FIXED

`InvoiceEvents.handlers/0` called `PhoenixKit.ModuleDiscovery.discover_external_modules/0`,
which walks every phoenix_kit-dependent dependency's `ebin` directory and reads
each `.beam` with `:beam_lib.chunks/2`, on **every call**. `enqueue/2` calls it
inside `do_record_transaction/4` / `mark_invoice_paid/2`, while the invoice's
`FOR UPDATE` row lock is held, and `resolve_handler/1` calls it again for every
job. Filesystem I/O proportional to the dependency tree on the hot money path,
under a row lock, is the wrong cost — and discovery is a compile/boot-time tool.

**Fix:** read `PhoenixKit.ModuleRegistry.all_modules/0` (a `:persistent_term`
populated from the same discovery at boot, plus runtime registrations; present
since before the 2.26 floor). `CoreCompat` swaps the entry. New test: a module
registered with the registry contributes its declared handlers.

### BUG - MEDIUM — New UI strings missing from the gettext catalogues — FIXED

`"Guest payer — no account"` (invoice detail) and `"guest"` (invoice list
badge) were added with `gettext/1` but never extracted, so `ru`/`et` rendered
raw English. `pot_drift_test.exs` only guards tab labels, so the suite stayed
green. **Fix:** added both msgids to `default.pot` by hand (a full
`gettext.extract` would drop the hand-maintained tab labels), ran
`mix gettext.merge priv/gettext`, translated `et` and `ru`.

### IMPROVEMENT - MEDIUM — Guest invoices printed a blank payer name — FIXED

The four print views (invoice, receipt, credit note, payment confirmation) take
the `billing_details` branch whenever the map is non-empty, and an individual
payer printed `first_name last_name`. A guest whose details carry only an email
(the minimum V5 requires) — or a `"name"` key, which the PR's own
`extract_user_name/2` reads — printed an empty line. **Fix:**
`Invoice.payer_name/1` (first + last, else `name`, else `payer_email/1`), used
by all four templates; unit-tested.

### IMPROVEMENT - MEDIUM — Mobile invoice cards showed "-" for guests — FIXED

The PR taught the desktop table cell to show the guest's billing email but not
the mobile card's `Customer` field (`invoices.html.heex`), which still read
`invoice.user`. Now falls back to `Invoice.payer_email/1`.

### IMPROVEMENT - MEDIUM — Order side effects still run before commit in `record_payment/3` — NOT FIXED

The PR's comment says PubSub now fires only after commit, but
`apply_transaction_to_invoice/2` still calls `maybe_mark_linked_order_paid/1`
inside the transaction, and `mark_order_paid/2` broadcasts `order_paid` there
(`handle_refund_transaction/1` → `mark_order_refunded` likewise). A listener can
still read the order before the change is visible, and a later rollback would
leave a broadcast for something that never happened. Pre-existing, and moving
it means threading order broadcasts back out through `mark_order_paid/2`'s
callers (it is also called standalone) — a wider refactor than this PR's scope.
Recorded for a follow-up; `mark_invoice_paid/2` already does it after commit.

### NITPICK — `:refunded` semantics undocumented — FIXED

`:refunded` fires on every refund, partial or full, and a full refund also
voids the invoice without a separate `:voided` event. A handler that treats
`:refunded` as "fully refunded" would be wrong. Documented in the
`InvoiceEvents` moduledoc.

### NITPICK — EveryPay displayed as "Everypay" — FIXED

`format_payment_method_name/1` fell through to `String.capitalize/1`. Added an
`"everypay" -> "EveryPay"` clause beside the other providers.

### NITPICK — `enqueue/2`'s rescue covers "Oban not running" only — NOT FIXED

A database-level failure inserting the job (e.g. no `oban_jobs` table) aborts
the Postgres transaction regardless of any rescue, so the payment rolls back.
That contradicts "a payment must never be rolled back because a notification
could not be queued" only for a host whose Oban is misconfigured at the schema
level; wrapping each insert in a savepoint to cover it adds cost to every
payment for a state `mix phoenix_kit.install` prevents. Left as is.

## What Was Done Well

- The event commits atomically with the payment; delivery re-reads the invoice.
- Job args never become a module call without matching the live registry.
- The V5 migration is catalog-guarded and idempotent, and `down/1` refuses
  instead of deleting or re-attributing money records.
- The EveryPay whitelist fix comes with a test pinning it to the provider
  registry, so the next provider cannot repeat the gap.

## Verdict

Approved with the fixes above applied on main.
