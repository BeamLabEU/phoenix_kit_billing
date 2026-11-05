# PR #27 — Declare rustler explicitly so mdex_native force-builds

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/27
**Author:** timujinne
**Head SHA:** `3abdd59`
**Status:** Merged; no findings

## Summary

`MDEX_NATIVE_BUILD=1` needs `rustler` itself, not only `rustler_precompiled`. The
dep is `optional: true`, so a consumer that does not force-build pulls nothing new,
and the comment gives the reason and points at core's matching declaration.

## Issues Found

None. `mix.lock` is not shipped, and `deps.unlock --check-unused` in the gate
accepts the entry.

## Verdict

Sound.
