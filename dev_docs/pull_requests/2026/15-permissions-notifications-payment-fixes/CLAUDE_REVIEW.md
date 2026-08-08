# Code Review: PR #15 — Split billing permissions, add notifications, fix provider payments

**Reviewed:** 2026-08-05
**Reviewer:** Claude (claude-opus-5[1m])
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/15
**Author:** Max Don (mdon)
**Head SHA:** 532175d0a87b64021815131dca91aa9fb0527ac5
**Merge SHA:** a37488fb0513c4da767e616f47ab7b2ddb3b731e
**Status:** Merged

## Summary

Three strands: four sub-permissions (`manage_orders`, `manage_invoices`,
`manage_subscriptions`, `manage_settings`) enforced through a new
`Web.Authz` on every mutating admin handler; a `Notifications` module with
separate admin and customer sub-types; and a set of money fixes in the
context — provider-driven payments were failing to insert entirely,
`record_payment/3` allowed overpayment, and `mark_invoice_paid/1` wrote a
receipt without a ledger row.

The permission work is thorough and the money analysis in the context is
right. **The problem is the blast radius of the headline fix.** Provider
payments never inserted before this PR, so both callers of
`record_payment/3` — `WebhookProcessor` and `SubscriptionRenewalWorker` —
had *never executed their success paths*. The PR verified the fix at the
context boundary (8 regression tests, all calling `Billing.record_payment/3`
directly) and never exercised either caller. Both were broken.

## Issues Found

### 1. [BUG - CRITICAL] Subscription renewal raises after charging the card, and Oban retries the charge — FIXED
**File:** `lib/phoenix_kit_billing/workers/subscription_renewal_worker.ex` line 254 (pre-fix)
**Confidence:** 97/100

The worker passes the provider's `%ChargeResult{}` struct as `provider_data`.
That column is `:map`, and Ecto lets a struct through **both** `cast` and
`dump` untouched (`Ecto.Type.of_base_type?(:map, …)` only rejects structs on
the `load`/validation side that this path doesn't reach) — the failure
surfaces in the JSON encoder as a **raise**, not `{:error, changeset}`.
Verified directly:

```
CAST: {:ok, %ChargeResult{...}}
DUMP: {:ok, %ChargeResult{...}}
JSON: RAISED: protocol Jason.Encoder not implemented for ChargeResult
```

Before this PR `provider_data` was silently dropped, so the struct never
reached the encoder. Carrying it through made the raise reachable, and it
lands in the worst possible place:

1. `Providers.charge_payment_method/3` succeeds — **the customer's card is
   charged.**
2. `Billing.record_payment/3` raises inside `repo().transaction/1`; the
   ledger row is rolled back.
3. The exception escapes `attempt_renewal/2`'s `with` (an `else` clause does
   not match exceptions), so the Oban job crashes rather than reaching
   `handle_payment_failure/2`.
4. Oban retries (`max_attempts: 3`). `create_renewal_invoice/1` writes
   *another* invoice and `charge_payment_method/2` **charges the customer
   again** — up to three times, with no ledger row for any of them.

**Fix applied:** a `jsonable/1` sanitizer in `build_transaction_attrs/4`
recursively converts structs (except `Decimal`/`Date`/`Time`/`DateTime`/
`NaiveDateTime`, which Jason handles) to plain maps. Placed at the library
boundary, not the call site: providers return these structs by design and a
host recording a payment from its own controller will pass whatever its
provider client returned. The worker now also handles a non-`:ok` record
result explicitly and logs the reconciliation-needed case.

### 2. [BUG - HIGH] Every successful provider webhook payment raises `KeyError` — FIXED
**File:** `lib/phoenix_kit_billing/utils/webhook_processor.ex` lines 182–191 (pre-fix)
**Confidence:** 98/100

```elixir
case Billing.record_payment(invoice, payment_attrs, nil) do
  {:ok, updated_invoice} ->
    if updated_invoice.status == "paid" do
```

`record_payment/3` returns the recorded **`%Transaction{}`**, and
`Transaction` has no `:status` field (`schemas/transaction.ex:27-41`) — so
`updated_invoice.status` raises `KeyError`. This branch was unreachable
until this PR made the insert succeed.

Consequence: the payment **commits**, then the webhook 500s. No receipt is
generated or sent, and the provider retries a charge that was already
recorded. On retry the new `:exceeds_remaining` guard rejects it, so the
webhook 500s again — until the provider disables the endpoint.

**Fix applied:** match `{:ok, %Transaction{}}` explicitly and re-read the
invoice for the receipt decision.

### 3. [BUG - MEDIUM] The webhook status gate and `Invoice.payable?/1` disagree — FIXED
**File:** `lib/phoenix_kit_billing/utils/webhook_processor.ex` line 474 (pre-fix)
**Confidence:** 90/100

`validate_invoice_status/1` admits `["draft", "sent", "overdue"]`. This PR
added `not Invoice.payable?(invoice) -> {:error, :not_payable}` to
`record_payment/3`, and `payable?/1` is `sent`/`overdue` only. A webhook for
a **draft** invoice therefore passes the processor's own gate and is
rejected downstream — the payment is dropped and the webhook errors, which
is the failure mode this PR set out to remove.

Two lists that must agree, kept in two places. **Fix applied:**
`validate_invoice_status/1` now delegates to `Invoice.payable?/1` (retaining
its distinct `:already_paid` clause), so they cannot drift again.

### 4. [BUG - MEDIUM] `mark_invoice_paid/2` discards a failed settlement insert — FIXED
**File:** `lib/phoenix_kit_billing.ex` line 2259 (pre-fix)
**Confidence:** 88/100

```elixir
_ = record_settlement_transaction(invoice, admin_user)
invoice |> Invoice.paid_changeset(receipt_number) |> repo().update!()
```

`repo().insert/1` returns `{:error, changeset}` rather than raising, and the
`_ =` throws it away — so the surrounding transaction **commits the status
without the ledger row**. That is precisely the inconsistency the
transaction was added to close, now able to recur silently.

**Fix applied:** `repo().rollback/1` on a failed insert.

### 5. [BUG - MEDIUM] `mark_invoice_paid/2` does not take the row lock `record_payment/3` relies on — FIXED
**File:** `lib/phoenix_kit_billing.ex` lines 2251–2264 (pre-fix)
**Confidence:** 85/100

The PR added `SELECT … FOR UPDATE` in `do_record_transaction/4` so two
concurrent payments cannot both pass the balance check. `mark_invoice_paid/2`
takes no lock and computes the outstanding balance from its own
pre-transaction read, so a mark-paid concurrent with a payment writes more
into the ledger than the invoice bills — the lock only serializes callers
that take it.

**Fix applied:** `mark_invoice_paid/2` takes the same lock and derives both
the outstanding amount and the `paid_changeset` from the locked row.

### 6. [BUG - MEDIUM] Every customer notification linked to a route that does not exist — FIXED
**File:** `lib/phoenix_kit_billing/notifications.ex` line 148 (pre-fix)
**Confidence:** 95/100

```elixir
defp customer_link(%{uuid: uuid}) when is_binary(uuid),
  do: Routes.path("/dashboard/invoices/#{uuid}")
```

There is no `/dashboard/invoices` route anywhere in the module.
`user_dashboard_tabs/0` registers exactly two customer paths, `orders` and
`billing-profiles`. Since an invoice always has a `uuid`, the first clause
always matched and the `/dashboard` fallback was dead — **every** customer
invoice and payment notification pointed at a 404, followed from an inbox,
an email or Telegram. It also hardcodes a URL, which `AGENTS.md` prohibits
("Centralized paths via `Paths` module").

**Fix applied:** `Paths.user_orders/0` (added alongside
`Paths.user_billing_profiles/0`), with a contract test asserting every
customer path is under a tab `user_dashboard_tabs/0` actually registers and
that `notifications.ex` never hand-rolls a `/dashboard` URL.

### 7. [BUG - MEDIUM] `billing.payment_failed` is registered but nothing emits it — FIXED
**File:** `lib/phoenix_kit_billing/notifications.ex` lines 103–113
**Confidence:** 93/100

`notification_types/0` registers `billing.payment_failed`, the moduledoc
explains why operators need it, and `payment_failed/2` had **zero call sites
in `lib/`**. It appears as a toggle in every operator's notification
preferences that can never fire.

More broadly, notification coverage stopped at the admin LiveView: the only
two call sites were in `invoice_detail/actions.ex`. The provider paths this
PR fixed — the webhook processor and the renewal worker — recorded payments
without telling anyone.

**Fix applied:** `payment_received/2` and `payment_failed/2` wired into both
provider paths. A contract test now fails if a registered action has no
producer.

### 8. [BUG - MEDIUM] A partial payment is announced as the invoice total — FIXED
**File:** `lib/phoenix_kit_billing/notifications.ex` line 82 (pre-fix)
**Confidence:** 90/100

`payment_received/1` formatted `amount(invoice)`, which reads
`invoice.total`. A 50-of-500 partial payment produced *"Payment received for
INV-1 — 500.00 EUR"*. An operator reconciling from notifications reads that
as settled.

**Fix applied:** `payment_received/2` takes the amount actually recorded
(falling back to the total when a caller has none) and all three call sites
pass it.

### 9. [BUG - LOW] `truncate/2` can cut a decline reason mid-codepoint — FIXED
**File:** `lib/phoenix_kit_billing/notifications.ex` line 184 (pre-fix)
**Confidence:** 92/100

`binary_part(text, 0, max)` cuts at a **byte** offset. Provider decline
reasons are frequently localized; splitting a multi-byte character yields an
invalid UTF-8 string that both Postgres and the JSON encoder reject — so the
notification reporting a failed payment fails itself. (It is caught by
`safely/1`, so the outcome is a silently missing notification.)

**Fix applied:** `String.length/1` + `String.slice/3`, with a test that
truncates 200 `é`.

### 10. [NITPICK] `Web.Authz` moduledoc describes the e-commerce module — FIXED
**File:** `lib/phoenix_kit_billing/web/authz.ex` lines 5, 63

Copy-paste from the sibling module: it names the base key as `"shop"` (it is
`"billing"`), justifies the mount guard with "carts carry customer contact
details", and says it redirects to "the shop admin dashboard". The code is
right; the doc describes a different module. **Fix applied.**

### 11. [OBSERVATION] `snapshot_refreshable?/1`'s doc overstates what it does — DOC CORRECTED, BEHAVIOUR UNCHANGED
**File:** `lib/phoenix_kit_billing.ex` lines 1399–1414

The doc says "while an order is still being prepared, a customer fixing a
typo in their address SHOULD see it on the order". It does not: the branch
that calls `put_snapshot/2` requires `profile.uuid != order.billing_profile_uuid`,
so an **in-place edit** of the profile an order already points at never
refreshes the snapshot — at any status, under any `billing_snapshot_policy`,
including `"always"`.

The same qualification applies to the PR description's motivation ("editing a
billing profile rewrote the address a historical order claimed to have been
billed to"): pre-PR, that only happened when an order was *switched* to a
different profile.

**Not changed.** Making edits refresh would require comparing the snapshot
field by field against the live profile, on the money path, to fix a
mismatch between a docstring and behaviour that is otherwise defensible. The
docstring now states the actual scope explicitly so the limitation is on
record rather than contradicted.

### 12. [OBSERVATION] The frozen branch keeps the new profile UUID but the old snapshot
**File:** `lib/phoenix_kit_billing.ex` `maybe_update_billing_snapshot/2`, frozen branch

`Map.delete(attrs, "billing_snapshot")` drops the snapshot but leaves
`"billing_profile_uuid"` in `attrs`, so a confirmed order can end up pointing
at profile B while its snapshot records profile A's address. Arguably
intended — the snapshot is the historical record and the pointer is current —
but the two now disagree with nothing recording that they may. Left as-is;
flagged for a deliberate decision.

## Notes on scope that were checked and found correct

- **Gating is complete.** All 32 mutating handlers across the touched
  LiveViews are behind `Authz.authorize/3`; the four print views guard on
  mount. The four LiveViews the PR did *not* touch (`orders`, `invoices`,
  `transactions`, `billing_profiles`) were checked handler by handler — every
  one is read-or-navigate only, so their absence from the diff is correct,
  not an oversight.
- **Owners and superadmins are not locked out.** `Scope.can?/2` resolves
  through `holds?/2`, which honours the `"*"` key that Owner holds by
  construction — consistent with what `Notifications.admin_recipients/1`
  documents.
- **Tab permissions match the capability each LiveView enforces** in all
  nine cases.
- **`Invoice.paid_changeset/2`** correctly tops `paid_amount` up to the total
  rather than overwriting, so it agrees with the new settlement row.

## What Was Done Well

The money analysis is genuinely good. `extract_user_uuid(nil)` returning
`nil` against a required `user_uuid` is exactly the kind of defect that hides
forever — it fails at insert, on a path nobody watches, after the customer
has been charged — and the diagnosis, the attribution decision (the
invoice's own user), and the `FOR UPDATE` re-check on the locked row are all
right. Comments explain *why* rather than *what*, and the
`:exceeds_remaining` / `:not_payable` errors the UI already rendered but the
context never returned is a sharp catch.

The permission split is disciplined: capabilities chosen by what an operator
would actually delegate, sub-permissions declared *and* enforced, denied-scope
tests that fail if a gate is removed, and an explicit upgrade warning about
custom roles. The audit-vs-notify action collision test is the kind of thing
that only gets written by someone who thought about how core derives
notifications.

## Verdict

**Approved with fixes.** The permission and notification work is sound, and
the context-level money fixes are correct. Two defects — one critical, one
high — came from the same gap: the PR fixed a function whose two production
callers had never run its success path, and verified the fix only at the
function. Both are fixed here, along with six smaller issues, and the
regression suite now covers the struct-`provider_data` path and the
status/ledger transaction. See `CHANGELOG.md` for 0.5.2.

## Testing note

This environment has no PostgreSQL, so the 190 DB-backed tests (including
the two regressions added here to `provider_payment_test.exs`) could not be
executed locally; 104 non-DB tests pass and `mix precommit` is green. The
three new contract tests were deliberately written as plain `ExUnit.Case`
so they run without a database — both defects they pin (a registered action
with no producer, a link to a nonexistent route) are invisible to a
DB-backed test anyway.
