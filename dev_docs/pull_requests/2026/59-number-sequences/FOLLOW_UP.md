# PR #59 — follow-up

## Codex — 2026-10-27

Resolved all three findings in `CODEX_REVIEW.md`:

- Imported receipt numbers advance the receipt counter atomically with the
  invoice insert, for both generated and supplied invoice numbers.
- Nil, empty and whitespace invoice-number options use generated numbers.
- Regenerated the V7 manifest and added an inventory guard that runs without
  newer core integration helpers.

Validation:

- Original focused baseline: 83 tests, 0 failures. Adding the receipt-import,
  blank-option and dashboard regression checks produced 4 failing tests;
  the standalone manifest-inventory regression also failed on the baseline.
- Combined numbering, real concurrency, inventory and permission tests:
  96 tests, 0 failures.
- Full `mix test`: 985 tests, 0 failures, 5 excluded because the pinned Hex
  core lacks the newer module-chain/manifest helpers.
- After extracting the counter-floor helper for Credo, reran numbering and
  inventory tests: 81 tests, 0 failures.
- Generated the manifest with local core's documented generator, using a
  scratch schema on `phoenix_kit_billing_test`: twelve tables. An additional
  local-core scratch-schema check verified a clean manifest, removed the
  counter's `last_value` column, confirmed its missing-column finding, repaired
  it and verified a clean manifest again. Scratch schemas were dropped.
- `mix format` and `mix precommit` passed. The gate included compilation with
  warnings as errors, the unused-dependency check, Hex audit, formatting,
  strict Credo and Dialyzer with the existing third-party exclusions.

The documented renewal/provider-call transaction limitation remains a separate
follow-up, with its reason recorded in the review.

## Claude — 2026-11-05

- **BUG - MEDIUM: blank number on update raised `not_null_violation` — fixed.**
  `require_stored_number/1` in both changesets returns "can't be blank" for `nil`,
  `""` and whitespace on a stored row. Regressions in `number_sequences_test.exs`
  fail without the fix.
- The renewal/provider-call limitation stays open, as recorded above.

### Update — 2026-11-05

- **The renewal/provider-call limitation is closed.** The invoice is created and
  committed before the charge (`Workers.SubscriptionCharge`), so no counter waits on a
  provider. Ownership is the subscription's and the invoice's row locks, and a
  period's invoice is found again by `metadata["period_end"]`, which is what stops a
  retry billing twice. Real-connection tests cover a second worker, a void and a pause
  during a charge. Only Stripe has an idempotency key, so with the other providers a
  crash past the charge can still charge twice, as it could before.
