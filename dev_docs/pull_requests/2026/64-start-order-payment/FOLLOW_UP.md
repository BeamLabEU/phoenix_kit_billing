# Review follow-up — 2026-10-29

Fixed non-Stripe invoice handling and remaining-balance checkout, added checkout request context to session reuse, and restored the legacy namespace delegate. The new provider request tests all failed before their fixes. Currency, return URL, email and compatibility regressions also failed on the review baseline.

Validation used the dedicated `phoenix_kit_billing_review_61_64_test` database
with the resolved Hex dependencies. The existing default database was below
the installed core's migration floor and was left intact.

- Full suite: 1,069 tests, 0 failures, integration tests enabled.
- Payment/refund/provider regressions: 69 tests, 0 failures.
- Final concurrency and provider-request checks: 7 tests, 0 failures.
- `mix precommit`: clean, including Dialyzer (only the three existing ignored warnings).
- `git diff --check`: clean.


## Claude — 2026-11-05

- **BUG - HIGH: order paid for a stale total — fixed.** New refusal
  `:invoice_out_of_date`, with an `Errors` message translated into et, ru and uk.
  **Open:** the admin payment path still has the gap; see the review.
- **BUG - MEDIUM: checkout context could wipe the void trail — fixed.** The write now
  runs on the locked row. The race test fails with the lock removed.
- **NITPICK: unmapped refusal atoms — not fixed**, because no page shows them.

### Update — 2026-11-05

- **The open admin path is closed.** `update_order/2` refuses a new total or currency
  while the order has an invoice that is neither void nor in the trash
  (`:order_amount_invoiced`), on a row taken `FOR UPDATE` so it waits for an invoice
  being inserted. `:invoice_out_of_date` stays for rows from before that rule.
- **`mark_invoice_paid/2`** moves the linked order in its own transaction now.
- **NITPICK: unmapped refusal atoms — fixed**, with translations.
