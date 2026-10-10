# Code Review: PR #51 — Ukrainian translations for the printed billing documents

**Reviewed:** 2026-10-10 (post-merge)
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/51
**Author:** timujinne (Tymofii Shapovalov)
**Merge:** 95406dc

## Summary

Only `priv/gettext/uk/LC_MESSAGES/default.po` changes (+642 lines): the strings
PR #48 added for the invoice, receipt, credit note and payment confirmation print
views, plus later wording fixes (no "EU" qualifier on the business label, clearer
payment-term / original-invoice / footer wording).

## Verification

- All 776 non-header entries are translated; no empty and no fuzzy entries; every
  `%{…}` / `{{…}}` placeholder matches its msgid; `Plural-Forms` is the 3-form
  Ukrainian rule.
- No Russian-only letters (`ы э ъ ё`) in any `uk` string. Strings identical to the
  `ru` catalogue are only placeholders (`IBAN: {{bank_iban}}`), shared words
  (`Кредит-нота`, `Банк`, `Валюта`) and `дн.`, all valid Ukrainian.
- `mix test` (816, 0 failures) including `pot_drift_test` and the catalogue
  coverage test for the shared form.

## Findings

### NITPICK — "Client Secret" and "Webhook Secret" left in English

Both are untranslated (same as msgid) in `uk`. They are provider-console terms
(Stripe, PayPal and Razorpay show them in English), so keeping them is defensible.
No change.

## Verdict

Approve. Nothing to fix.
