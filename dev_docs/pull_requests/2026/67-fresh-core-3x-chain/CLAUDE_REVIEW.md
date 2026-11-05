# PR #67 — Fix billing's chain on a fresh core 3.x database, and never lower its marker

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/67
**Author:** mdon
**Head SHA:** `ceec8ed`
**Status:** Merged; one test gap closed

## Summary

Fixes two real failures. Host files pinned below V6 failed on core 3.x, which no longer
creates billing's tables, and ecommerce running the chain first let older host files
lower the marker. Building the statements before the guard keeps a bad target refused
even on a newer database, and `flush/0` before the marker read handles two chain calls
in one migration. `marker_to_version/1` reads a missing table and an unstamped table
both as 0, as before.

## Issues Found

### IMPROVEMENT - MEDIUM — Only target 4 was tested on an empty schema — fixed

The PR's claim is about every older target, and `phoenix_kit_orders` arriving at target
3 could have referenced something that arrives later. A probe ran all eight targets on
an empty schema, and each built and stamped its own version, so the claim holds. The
test now enumerates `1..current_version()` and carries each on to current, so a future
version cannot regress an older pin unnoticed.

## What Was Done Well

- The commit messages explain the mechanism, and the guard's ordering is commented.
- The test runs the chain through a real `Ecto.Migration` runner.

## Verdict

Sound. The code was right; the test now proves all of it.
