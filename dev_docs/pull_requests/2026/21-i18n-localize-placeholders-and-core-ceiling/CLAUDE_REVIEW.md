# Code Review: PR #21 — Localise the profile form placeholders, and stop blocking hosts on newer core

**Reviewed:** 2026-08-17
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/21
**Author:** timujinne (Tymofii Shapovalov)
**Head SHA:** f20375692c477ab5a5e92e0b432d01f5f3dd29ce (merge commit)
**Status:** Merged

## Summary

The PR branch carried two changes per its description: localized billing-profile
placeholders, and a widened `:phoenix_kit` core version ceiling backed by a new
`PhoenixKitBilling.CoreCompat` contract-checking mechanism.

In practice, only the second half landed with any diff. The placeholder commit
on this branch was byte-identical to what PR #20 (`8836181`) had already merged
to `main` five days earlier, so the three-way merge produced zero changes for
it — placeholder localization is real and already shipped, just not by this PR.

The core-ceiling half went through more history than the PR description
implies: the branch's own attempt to widen the pin to
`">= 1.7.214 and < 3.0.0"` (`a0af295`) was superseded when the branch merged
`upstream/main` and *deliberately kept* the tighter `~> 2.0` pin from the
0.7.0 release (`bfc7745`) — core 2.0.0 squashed the migration chain to a
`V135` floor, so 1.7 support was correctly dropped, not merely widened. What
survived and actually landed is the durable value: `PhoenixKitBilling.CoreCompat`,
a declared inventory of every core API surface billing depends on (29 unguarded
calls, 3 guarded, 15 `use`/`import`ed modules), self-checked against billing's
own AST so an undeclared call site can't silently escape the guard, checked at
boot (`Supervisor.init/1`) and in `test/phoenix_kit_billing/core_api_contract_test.exs`.

## Issues Found

### 1. [BUG - MEDIUM] Stale moduledoc claims core.exs admits 1.7.214–3.0.0 — FIXED
**File:** `lib/phoenix_kit_billing/core_compat.ex` lines 6-7 (also
`test/phoenix_kit_billing/core_api_contract_test.exs` lines 6-8)
**Confidence:** 95/100

Both moduledocs stated `mix.exs` admits "any core from 1.7.214 up to (but not
including) 3.0.0," carried over verbatim from the branch's earlier `a0af295`
commit. The merge with upstream (`bfc7745`) intentionally reverted `mix.exs`
to `~> 2.0` and rewrote `AGENTS.md` and
`test/core_pin_conformance_test.exs` to match — but the two files added later
in this same branch (`core_compat.ex`, `core_api_contract_test.exs`) were never
updated, so they now ship a claim that directly contradicts the actual
requirement, `AGENTS.md`, and the conformance test that enforces it
(`core_pin_conformance_test.exs` explicitly asserts core `1.7.236` and `1.9.4`
are *rejected*). A host operator reading `CoreCompat`'s docstring would
conclude a core 1.8 upgrade is safe to attempt; `mix deps.get` would refuse it
outright. Fixed both moduledocs to state the real requirement (`~> 2.0`, core
1.7 excluded) and point at `core_pin_conformance_test.exs` as the source of
truth, matching `AGENTS.md`'s wording.

`lib/phoenix_kit_billing/supervisor.ex`'s boot-log comment ("mix.exs admits
core up to 3.0.0") only states the upper bound and isn't wrong on its own, so
left as-is.

## What Was Done Well

- `CoreCompat`'s self-verifying test (`covers every core call in billing's own
  source`) re-derives the call inventory from the AST rather than trusting the
  hand-written list to stay complete — the exact mechanism that keeps this kind
  of tool from going stale within a release or two.
- The PR body was upfront about incomplete verification (DB-backed tests
  excluded, no local Postgres) rather than claiming a green run it didn't have.
- `bfc7745`'s merge commit message is a good record of *why* the branch's own
  widened pin was overridden rather than kept — worth the read for context this
  review doc doesn't repeat.

## Verdict

**Approved with fixes.** The core-compat contract-checking mechanism is sound
and already covered by its own tests; the one real defect was doc drift
introduced by history the PR's own description doesn't mention, now fixed.
`mix precommit` (format, compile --warnings-as-errors, credo --strict,
dialyzer) and `mix test` (311 tests, 0 failures, 4 pre-existing skips per
AGENTS.md's documented core V65 defect) both pass clean.
