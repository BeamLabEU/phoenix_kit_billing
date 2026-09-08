# Code Review: PR #35 — Standardize AGENTS.md onto the shared module skeleton

**Reviewed:** 2026-09-08
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/35
**Author:** Max Don (mdon)
**Head SHA:** 07d7116
**Status:** Merged

## Summary

Pure documentation PR: rewrites `AGENTS.md` (513 → 488 lines) onto a shared
skeleton format used across the `phoenix_kit_*` module family, adds a
`CLAUDE.md` symlink pointing at it, and adds one test
(`test/phoenix_kit_billing_test.exs`) pinning `Billing.version/0` against
`Mix.Project.config()[:version]`.

## Verification

- Spot-checked the rewritten doc's factual claims against the current
  codebase rather than trusting prose:
  - `pkb_schema:<N>` marker and `@current_version 3` — confirmed in
    `lib/phoenix_kit_billing/migrations.ex`.
  - "Four tests carry `@tag :skip`" (subscription persistence landmine) —
    confirmed exactly 3 in `context_test.exs` + 1 in `listing_lvs_test.exs`
    (a naive `grep -c` first over-counted by matching the word `@tag :skip`
    inside an explanatory comment; re-checked against actual `@tag` lines).
  - `dev_docs/agentic_commerce_payments.md` (linked from the new Feature
    notes table) exists.
  - `elixirc_options: [ignore_module_conflict: true]` and the
    `compat/billing.ex` TODO — confirmed in `mix.exs`.
  - `Billing.version/0` genuinely reads `Mix.Project.config()[:version]` at
    compile time (`lib/phoenix_kit_billing.ex:159`), matching the new test
    and the doc's versioning section — not a hardcoded string that could
    drift.
- `CLAUDE.md` is a real symlink (`new file mode 120000` → `AGENTS.md`), not a
  copy that could drift from the file it's supposed to mirror.
- No code paths changed; risk is confined to stale/incorrect documentation,
  and spot checks found none.

## Issues Found

None.

## Verdict

**Approved, no changes.**
