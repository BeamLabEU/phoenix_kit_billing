# PR #63 — Add a require_phone option to the billing profile fields

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/63
**Author:** timujinne
**Head SHA:** `372db91`
**Status:** Merged; no findings

## Summary

Mirrors `require_email`: the changeset option, the component attr threaded through
both the individual and company cards, and the HTML `required` marker. The attr is
`required: true` on the private cards, so a missed pass-through is a compile warning,
which the gate's `--warnings-as-errors` turns into a failure.

## Issues Found

None. The tests cover both profile types, whitespace, the optional default and
independence from the other options. No new msgid.

## Verdict

Sound.
