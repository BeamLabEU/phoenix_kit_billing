# PR #73 — Translate the account menu's billing tabs into German and French

**Author:** timujinne · **State:** merged 2026-11-24 (`b120048`) · **Reviewed:** 2026-11-24

Pure gettext change: the `de` and `fr` catalogs had empty `msgstr` for the account menu's
billing tabs ("My Orders", "Billing Profiles") and the 44 customer-visible strings of the pages
behind them (order list, billing profiles, profile form). No code change; only `msgstr` lines
edited, no `#:` reference changes, no fuzzy flags.

**Verdict:** merged. No findings.

## Checked, fine

- Only `priv/gettext/de/LC_MESSAGES/default.po`, `priv/gettext/fr/LC_MESSAGES/default.po` and
  `test/phoenix_kit_billing/i18n_test.exs` changed (153 insertions, 92 deletions); the diff
  touches no `msgid` or `#:` lines — hand edits confined to translations, as the PR body
  claims. Spot-checked: every added msgstr is non-empty and the msgids match existing entries.
- The new tests in `i18n_test.exs` resolve the tab labels and a sample of the page strings
  under `de` and `fr` through the gettext backend, so an empty msgstr fails the suite.
- Shared msgids (invoice/receipt wording) also improve the admin screens and print documents
  in those locales — a free side effect, noted in the PR body.
- Deliberately out of scope, and the PR body says so: the order/invoice status badges and the
  Individual/Company badge are rendered with `String.capitalize/1`, not gettext, so they stay
  English. That needs a code change, not catalog entries — recorded here as the known
  follow-up.

## Validation

- `mix compile --warnings-as-errors` clean; `mix test test/phoenix_kit_billing/i18n_test.exs` —
  0 failures.
- `mix precommit` — exit 0.
