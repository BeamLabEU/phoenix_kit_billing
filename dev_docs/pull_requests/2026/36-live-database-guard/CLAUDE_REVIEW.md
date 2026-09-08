# Code Review: PR #36 — Refuse to run the test suite against a known live database

**Reviewed:** 2026-09-08
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/36
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 65fe4bd
**Status:** Merged

## Summary

Adds `PhoenixKitBilling.Test.LiveDatabaseGuard.check!/1`, called from
`test_helper.exs` before anything touches the database. It raises
`LiveDatabaseError` if the resolved test database name exactly matches one of
three hardcoded live databases known to exist in this dev container
(`phoenix_kit_dev`, `decor_3d_print_dev`, `phoenixkit_hello_world_dev`) — a
second line of defense alongside an external, unversioned wrapper script
(`pk-test`) that already refuses this outside the repo. Ships with two test
files: a pure unit test of `check!/1`'s decision logic, and a wiring test that
actually shells out to `mix test` as a subprocess (with `PGHOST` pointed at an
unreachable address) to prove `test_helper.exs` really calls the guard, not
just that the guard's logic is correct in isolation.

## Verification

- `check!/1` is an exact match against the hardcoded list, not a substring
  match — confirmed by the "looks like it but isn't" test case
  (`"phoenix_kit_dev_backup"`, `"not_phoenix_kit_dev_but_looks_like_it"` both
  pass through as `:ok`).
- Confirmed the wiring test's core claim: it distinguishes "the guard fired"
  from "the ordinary unreachable-database fallback caught it instead" by
  asserting on the specific exception name in subprocess output, not just a
  nonzero exit code — a cut wiring call would still exit nonzero-free (0,
  actually) via the pre-existing fallback, so a bare exit-code check would
  pass on broken wiring. The test's own docstring records that this was
  verified live (call commented out → exit 0, no `LiveDatabaseError` in
  output) rather than assumed.
- `check!/1` is invoked after `live_database_guard.ex` is added to the
  `Code.require_file/2` list and before `db_name` is used anywhere else in
  `test_helper.exs` — no load-order hazard.
- This is dev-container-specific safety tooling (hardcoded database names
  particular to the author's machine), not portable logic, but it's
  additive, degrades to a no-op on any other machine, and is exercised by
  its own tests rather than only trusted by inspection.

## Issues Found

None.

## Verdict

**Approved, no changes.**
