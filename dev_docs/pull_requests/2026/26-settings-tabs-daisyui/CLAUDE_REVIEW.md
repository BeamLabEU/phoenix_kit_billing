# PR #26 — Add a SettingsTabs component, drop the four duplicated strips, and fix the daisyUI tabs class

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/26
**Author:** mdon
**Head SHA:** `87d05ce`
**Status:** Merged; one stale-doc finding fixed

## Summary

Four hand-copied tab strips become one component over core's `<.nav_tabs>`. Each
page passes its own `active_tab`, and currencies keeps its smaller size through
`class="tabs-sm"`. Independent of `GROK_REVIEW.md`, whose alias fix is in place
(`provider_settings.ex` has one `Routes` alias).

Checked against the resolved core 3.3.0: `nav_tabs` still accepts `:path` as its
legacy spelling and runs it through `Routes.path/1`, while `:navigate` and `:patch`
pass through verbatim. The raw paths are therefore correct, not a `Paths`
convention miss: `Paths` output is already prefixed and would double-prefix here.

## Issues Found

### NITPICK — The `:path` rationale described a pin that no longer exists — fixed

The `@doc` justified `:path` by the `~> 2.0` pin and the risk of dead tabs on older
cores. The floor is now 2.65.0, so that reason is gone, while the key is still
right for a different reason: these paths are unprefixed and only `:path` applies
the route helper. Left alone, the old text invites swapping the key, which would
under-prefix every link. Rewrote the note around the reason that still holds.

## What Was Done Well

- One definition instead of four, with `values:` on `active_tab` flagging a typo at compile time.
- The strip inherits core's roles and styling instead of restating them.

## Verdict

Sound. Doc text only.
