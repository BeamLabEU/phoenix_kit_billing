# Code Review: PR #41 — Fail-closed PayPal webhook signature verification

**Reviewed:** 2026-09-09
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/41
**Author:** timujinne (Tymofii Shapovalov)
**Head SHA:** d3378ef0f0aa0d8610ff68fc4df23bf3ab35b6ad
**Status:** Merged (f5cb08c)

## Summary

One-line production fix plus a new destructive test file, confined to
`lib/phoenix_kit_billing/providers/paypal.ex` and
`test/phoenix_kit_billing/web/paypal_webhook_signature_test.exs`.

`PayPal.verify_webhook_via_api/3` has two clauses: one guarded
`when is_map(headers)` that calls PayPal's real verify-webhook-signature API,
and a catch-all for everything else. `WebhookController.paypal/2` reads the
signature with `get_signature/2`, which always extracts a single header value
as a **string** (identical to the Stripe/Razorpay path) — so the guarded
clause can never match in production and every real invocation fell into the
catch-all. That catch-all used to return `:ok` unconditionally: fail-open —
any PayPal webhook request, forged or not, was accepted and processed as a
genuine payment event. The fix flips the catch-all to
`{:error, :invalid_signature}` — fail-closed.

A second, unrelated hunk in the same PR adds a `:paypal_req_options`
Application-env seam merged into the OAuth token request opts, so the new
test can stub PayPal's token endpoint via `Req.Test` instead of hitting the
network or needing real credentials.

## Verification performed

- Read the full diff (`git show f5cb08c -m --first-parent`) and the complete
  current `paypal.ex` and `webhook_controller.ex`.
- **Confirmed the pre-PR bug for real**, not just from the PR description: the
  catch-all clause returned `:ok` before this change (checked via the diff
  hunk directly).
- **Confirmed the fix's precondition — headers are always a string in
  production, never a map** — by grepping every call site of
  `verify_webhook_signature`/`verify_webhook_via_api` in `lib/`: the only
  production caller is `WebhookController.handle_webhook/3` →
  `verify_signature/4` → `Providers.verify_webhook_signature/4` →
  `PayPal.verify_webhook_signature/3`, and `get_signature/2` in the
  controller always does `[signature | _] -> {:ok, signature}` (a binary,
  never a map). So the `is_map(headers)` clause is genuinely dead code from
  production's perspective, and the fix's own test docstring discloses this
  scope limitation honestly rather than hiding it.
- **Traced the two new tests' status codes against the real controller path**
  (not a reimplementation): missing signature → `get_signature/2` returns
  `{:error, :no_signature}` → falls to the generic `{:error, reason}` branch
  → 400 `"Processing failed"`. Forged signature → reaches
  `verify_webhook_via_api/3`'s catch-all → `{:error, :invalid_signature}` →
  401 `"Invalid signature"`. Both match `webhook_controller.ex`'s existing
  branch table exactly; the PR added no new controller branches.
- **Verified the `:paypal_req_options` test seam is inert in production** —
  grepped the whole repo; the key is never set in `config/`, `test/support/`
  config, or anywhere outside this one `Keyword.merge` call and the new test.
  `Keyword.merge(defaults, test_overrides)` lets the test-supplied `:plug`
  key ride alongside `:headers`/`:body` with no key collision.
- Ran `mix precommit` (compile `--warnings-as-errors`, format,
  `credo --strict`, dialyzer, `deps.unlock --check-unused`, `hex.audit`) —
  **clean, exit 0**.
- Ran the full suite against a reachable `phoenix_kit_billing_test` database:
  **570 tests, 0 failures, 4 skipped** (the four pre-existing
  `subscription_type_uuid` core-chain-gap skips, unrelated to this PR).
- Ran the new file in isolation with `--trace`: all 3 tests pass, including
  the regression guard ("OAuth succeeding is not, by itself, enough to accept
  the request") that would catch a future "fix" that short-circuits on token
  exchange instead of actually checking the signature.

## Issues Found

None that block approval or need fixing here. Two informational notes, both
already effectively disclosed by the PR author:

- **[INFO — already disclosed]** Because the guarded (real, API-calling)
  clause is provably unreachable from the controller today, this fix makes
  *every* PayPal webhook — forged or genuine — return 401. The PayPal
  webhook path is now fully non-functional for legitimate traffic until a
  follow-up collects PayPal's five `paypal-transmission-*`/`paypal-cert-url`
  headers into a map and fixes the dispatch. Trading "silently accepts
  forged payment-completion events" for "correctly rejects everything,
  including real ones" is the right default (fail-closed) for a payments
  webhook, and the new test's own moduledoc states this trade-off and the
  deferred follow-up explicitly — not a gap introduced silently by this
  review.
- **[INFO — non-blocking]** The test moduledoc and one code comment reference
  "the B008 report" for further detail; no such document exists anywhere in
  this repository (checked `dev_docs/` and a full-repo grep). Likely an
  external tracker reference (ticket ID), not a dangling repo link — nothing
  to fix, just noting it isn't independently verifiable from inside this
  checkout.

## What Was Done Well

- Minimal, surgical diff: the actual security fix is a one-token change
  (`:ok` → `{:error, :invalid_signature}`); the OAuth-opts hunk exists solely
  to make that fix testable without live PayPal credentials.
- The new test drives the real `WebhookController.paypal/2` action end-to-end
  and asserts on the HTTP response, not a reimplementation of the
  verification logic or a log line — it would have caught the original bug.
- Includes a deliberate negative/regression test (OAuth-succeeds-is-not-
  enough) guarding against the most likely wrong "fix" a future contributor
  might attempt.
- The moduledoc is unusually honest about the fix's remaining limitation
  (webhook path now fully rejects legitimate traffic pending the larger
  multi-header fix) rather than presenting this as a complete solution.
- The `:paypal_req_options` test seam is scoped narrowly (one `Req.post`
  call), documented inline as production-inert, and verified so by this
  review.

## Verdict

**Approved. No changes made.** The fix correctly closes a fail-open forged-
webhook acceptance bug on the payments-money path, is covered by tests that
exercise the real HTTP entry point, and ships with an honest account of its
own remaining scope. `mix precommit` is clean and the full suite passes
570/570 (4 pre-existing, unrelated skips). Already merged to `main`.
