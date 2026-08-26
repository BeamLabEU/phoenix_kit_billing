# Code Review: PR #29 — Add migration_module/0, adopt payment provider configs table

**Reviewed:** 2026-08-26
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/29
**Author:** timujeen (timujinne)
**Head SHA:** 1fd662ad753554d9520e93025058bfebcb3cdb7c
**Status:** Merged (3831481)

## Summary

Adds `PhoenixKitBilling.migration_module/0` and a new
`PhoenixKitBilling.Migrations` module implementing core's decentralized
module-migration protocol (`current_version/0`, `migrated_version_runtime/1`,
`up/1`, `down/1`). The target is `phoenix_kit_payment_provider_configs`, a
core-created (V135 baseline) table this package's application code does not
yet read or write — provider credentials still live in `phoenix_kit_settings`.
V1 is a pure *adoption* step: it re-issues core's exact V135 DDL
(`CREATE TABLE IF NOT EXISTS`, same index/constraint names) and stamps a
`pkb_schema:1` marker comment on the table, after which this module's chain
owns the table's future shape. `down/1` only ever rewrites the marker comment
— it never drops the table, since core's own baseline rollback owns that.

The PR ships as two commits: the initial implementation (e40ab08) and a
self-review follow-up (1fd662a) that fixed a swallowed-`ArgumentError` bug in
`migrated_version_runtime/1`, added a runtime guard on `down_statements/2`'s
`target`, and added `migrations_runtime_test.exs` to cover the DB read path.

## Verification performed

- Cross-checked `up_statements/1`'s `CREATE TABLE` against core's actual V135
  DDL in `/workspace/phoenix_kit/lib/phoenix_kit/migrations/postgres/v135.ex`
  — column list, types, and defaults are byte-for-byte identical.
- Cross-checked `not_null`/`default`/`type` per column against core's
  `ExpectedSchema.objects/1` manifest — matches (this duplicates what
  `migrations_test.exs`'s "V1 stays aligned with core's manifest" test
  already asserts, verified independently against the actual core source
  rather than trusting the test's own fixture).
- Verified the `reraise e, __STACKTRACE__` fix in `migrated_version_runtime/1`
  mirrors core's own established fix for the identical bug class, almost
  verbatim, in `phoenix_kit/lib/phoenix_kit/migrations/postgres.ex`'s
  `migrated_version_runtime/1` — the PR's commit message claim ("same class
  of bug core's migrations already fixed") checks out.
- Verified the `down(prefix: ..., version: ...)` keyword-list-only call shape
  claim against `phoenix_kit/lib/mix/tasks/phoenix_kit.update.ex:1178`, which
  does codegen exactly that literal call — the map-opts branch left
  unreachable in `down/1` is correctly documented as dead-in-practice, not a
  bug.
- Confirmed `phoenix_kit_legal`'s sibling `migration_module/0` /
  `Migrations` chain uses the identical protocol and marker-comment
  convention this PR follows.
- Ran the full gate: `mix precommit` (compile --warnings-as-errors, format,
  credo --strict, dialyzer) — clean. `mix test` — 353 tests, 0 failures, 4
  skipped (pre-existing, unrelated core-migration skips). The new
  `migrations_test.exs` (16 pure data/string tests) and
  `migrations_runtime_test.exs` (3 DB-backed tests) all pass.

## Issues Found

None. I could not find a correctness, safety, or contract issue that the
PR's own self-review commit (1fd662a) hadn't already caught and fixed. The
test suite added for this module is unusually thorough for the risk here —
it asserts the exact SQL operation set `up/1` emits, proves no statement in
either direction can contain `DROP`/`TRUNCATE`/`DELETE`, and proves via
source-text inspection that `up/1`/`down/1` execute only what
`up_statements/1`/`down_statements/2` build (closing the gap where a test
suite checks builder output but the runtime function does something else).

## What Was Done Well

- Correctly scopes V1 to adoption-only (no shape change), which means core's
  `ExpectedSchema` manifest for this table stays valid and no core release is
  required to ship this — a materially smaller-blast-radius choice than
  bundling a shape change into the first version.
- `down/1` is designed so it structurally cannot destroy the core-created
  table — the moduledoc calls this out explicitly, and the test suite
  enforces it both from the builder's output and from the executing
  functions' own source text.
- The self-review commit (1fd662a) independently found and fixed the same
  class of bug this reviewer would have flagged (swallowed `ArgumentError`
  in the runtime read path misleading an operator into thinking the module
  is uninstalled), and added test coverage for the previously-untested DB
  read path.

## Verdict

**Approved.** No changes made — the PR as merged is correct, matches core's
V135 shape and protocol conventions, and the gate is clean.
