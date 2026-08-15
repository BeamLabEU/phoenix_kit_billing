# PR #20 — Localize the example placeholders in the billing profile forms

**Reviewed:** 2026-08-13 · **Author:** @timujinne · **Verdict:** merged unchanged.

## Summary

Routes five hardcoded placeholders (`John`, `Doe`, `Tallinn`, `Harju`,
`Acme Corp OÜ`) through `gettext/1` in `billing_profile_form.html.heex` and
`user_billing_profile_form.ex`, and adds the msgids to `default.pot` plus the
`et`, `ru` and `en` catalogues.

Small, correct, no findings.

## Checked

- **No msgid collision.** Single-word proper nouns are the weak point of
  untagged gettext msgids — `John` or `Tallinn` acquiring a second, unrelated
  meaning elsewhere in the package would tie the two together. Grepped for each
  of the five: the only other occurrences are in
  `schemas/billing_profile.ex:36-52`, which are moduledoc example data, not
  `gettext/1` calls. Nothing to collide with, so no `pgettext` context is
  needed today.
- **Both forms were updated.** The two profile forms are near-duplicates
  (one `.heex` template, one LiveComponent with inline markup) and it would have
  been easy to fix one and miss the other. All five placeholders changed in both.
- **The `et` and `ru` catalogues carry real translations**, not empty msgstrs:
  `John` → `Jaan` / `Иван`, `Doe` → `Tamm` / `Иванов`, `Tallinn` → `Таллинн` in
  `ru`. `Acme Corp OÜ` is intentionally identical in all three — a company name
  does not translate, but having the msgid lets a locale override it.
- **The literal-vs-translated split is the right one.** Leaving
  `john@example.com`, `+372 5555 5555`, `EE123456789`, `12345678` and `10115`
  untranslated is correct: those are format demonstrations, and translating a
  VAT-number shape would make it wrong rather than localized.

## Noted, deliberately out of scope

The PR reports that `mix gettext.extract --merge` on this branch finds **71
messages present in the code but missing from the catalogues**, and that the
fuzzy matcher mistranslates several (`Manage invoices` → `Halda valuutasid` —
"manage currencies"; `Subscription extended by %{days} days` → a string with a
hardcoded 30). Folding that in here would have merged a batch of wrong Estonian
behind a five-string change. Keeping it to a separate pass with per-entry review
of the fuzzy flags is the right call, and it is worth doing — 71 untranslated
strings is most of this package's UI.
