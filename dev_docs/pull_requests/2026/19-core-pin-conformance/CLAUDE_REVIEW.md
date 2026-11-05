# PR #19 — Add a conformance test for the :phoenix_kit requirement

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/19
**Author:** mdon
**Head SHA:** `9d62d21`
**Status:** Merged; one stale-text finding fixed

## Summary

The test guards a real consumer-only failure: a pin narrowed to one core minor
breaks `mix deps.get` for every host, and nothing in this repo's own run sees it.
Resolving the dep first and falling back to the committed literal keeps it useful
under `PHOENIX_KIT_PATH` while still failing on a committed `path:` dep. The
design has aged well through four floor raises.

## Issues Found

### NITPICK — The pin's documentation lagged the pin — fixed

`mix.exs` is `>= 2.65.0 and < 4.0.0` (since 8499a63), and the test's `@must_admit`
and `@must_reject` follow it. The prose did not: the failure message still told a
reader to keep `>= 2.44.0 and < 3.0.0`, the moduledoc stopped at that floor, and
`AGENTS.md` and `README.md` still described 2.44.0 and "every core 2.x and nothing
else". Following the failure message literally would have re-excluded core 3.x.

Updated the failure message, the moduledoc, `AGENTS.md` (the "Depends on" line and
"Core compatibility") and `README.md`. The reasons come from the 0.24.0 CHANGELOG
entry. Historical CHANGELOG entries are unchanged.

## What Was Done Well

- The check fails on the mistake that matters and passes on the sanctioned override.
- The two-source lookup is explained where a future reader would otherwise "simplify" it.

## Verdict

Sound. Only the surrounding text had drifted.
