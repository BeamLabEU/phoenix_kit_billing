# Code Review: PR #45 — Write per-domain-currency spec references in English (E1/E2/E5, item 5)

**Reviewed:** 2026-09-28
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/45
**Author:** timujinne
**Head SHA:** 675aab0
**Status:** Merged (e18d2fe)

## Summary

Comment/docstring and test-name change only, across 25 files (48 lines).
Cyrillic stage labels `Э1/Э2/Э5` become `E1/E2/E5`, the section marker `п.N`
becomes `item N`, and one Russian example date (`"17 авг 2026"`) in a
`user_orders.ex` comment becomes a prose description. Nothing executable
changed: no code, no string literals asserted by tests, no gettext msgids.

## Verification

- Diffed every hunk: each one is inside a `#` comment, a `@moduledoc`/`@doc`,
  or a `describe`/`test` name. Test names are not referenced anywhere else.
- Remaining Cyrillic under `lib/` and `test/` is data, not prose, and must stay:
  - `lib/phoenix_kit_billing/web/components/currency_display.ex` — `"лв"`, the
    BGN currency symbol.
  - `test/phoenix_kit_billing/i18n_test.exs` — asserts the `ru` translation
    `"Биллинг"`.
  - `test/phoenix_kit_billing/web/user_orders_test.exs` — asserts the `ru`
    date `"07 Авг 2026"`.
- The reworded `user_orders.ex` comment ("same order with a localized month")
  still matches `localized_date/1`'s behaviour and its test.

## Findings

### IMPROVEMENT - MEDIUM — CHANGELOG still used the Cyrillic stage labels (fixed)

`CHANGELOG.md` kept `stage Э5` (0.14.0) and `stages Э2 and Э3` (0.13.0), so the
shipped Hex docs no longer matched the code comments they point to. It's also
the one Hex-published file that non-Russian readers see. **Fixed:** both
headings now read `E5` / `E2 and E3`.

### NITPICK — Earlier review docs keep `Э` labels (left as-is)

`dev_docs/pull_requests/2026/{32,33,34,38,40}-*/CLAUDE_REVIEW.md` still say
`Э1`…`Э5`. They are dated records of what was reviewed then, so they're left
unchanged. The `e1`…`e5` directory slugs already map one-to-one.

### NITPICK — No guard against reintroduction (not added)

A test that scans `lib/` and `test/` for Cyrillic would need an allowlist for
the three legitimate data cases above, and it would change whenever a
translation assertion is added. That upkeep costs more than it saves for a
comment-language rule, so none was added.

## Gate

`mix format` + `mix precommit` clean (dialyzer: 2 known warnings, both
filtered by the ignore file); `mix test`: 620 tests, 0 failures, 4 skipped.
