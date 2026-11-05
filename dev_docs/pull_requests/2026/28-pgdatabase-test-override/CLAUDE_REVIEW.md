# PR #28 — Make the test database name overridable via PGDATABASE

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/28
**Author:** timujinne
**Head SHA:** `15426b0`
**Status:** Merged; no findings

## Summary

`PGDATABASE` overrides the test database name, and the comment records the known
cost (it takes precedence over `MIX_TEST_PARTITION`). Exercised for real in this
review: the shared `phoenix_kit_billing_test` database sits at core V224, below
core 3.3.0's V225 floor, so `test_helper.exs` excludes every integration test
(270 run, 1104 excluded). A dedicated database through this override ran all of them.

## Issues Found

None in this PR.

## Notes

The one failure in that degraded run, `enabled?/0 returns false without DB`, comes
from the stale database and not from the code. The helper's "Could not connect"
wording is also loose for a database that connected but is below the floor. Neither
was changed here: `mix test.reset` is the documented cure, and it drops a shared
database, so that is the maintainer's call.

## Verdict

Sound, and it was the reason this review could run the whole suite without touching
the shared database.
