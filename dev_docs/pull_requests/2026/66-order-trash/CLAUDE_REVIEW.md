# PR #66 — Trash for orders and draft invoices (V8)

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/66
**Author:** timujinne
**Head SHA:** `f942172`
**Status:** Merged; all findings fixed

## Summary

The trash is well bounded: only drafts and cancelled orders, the number stays used,
nothing purges it, and every path re-reads the stored row. `FOR KEY SHARE` before the
invoice counter gives trash and invoice creation a clean meeting point. `gh pr diff`
for this PR includes #65; the review used the first-parent diff of the merge.

Checked: every subscriber of the new events has a catch-all (`Orders`, `Invoices`,
both detail pages, ecommerce's `checkout_complete`); every listing and dashboard
aggregate scopes the trash, while the unscoped reads (`get_order/2`, the currency usage
count, `rows_of_year/2`) are deliberate; `trash_invoice` and `restore_invoice` are
gated on `manage_invoices` and the order pair on `manage_orders`; V8's `up` and `down`
statements match the moduledoc.

## Issues Found

### IMPROVEMENT - MEDIUM — 48 Estonian strings were copies of the English — fixed

The commit "the trash strings in the pot and every catalogue" added them to `et` as
`msgstr == msgid`, covering the whole trash UI and #65's void and cancel modals. `et`
is a supported locale, and `pot_drift_test` cannot see this, because a copy is not
empty. Translated using the catalogue's existing terms and formal register, with
placeholders checked to match.

**The Estonian was not written by a native speaker and should be checked by one.**

### IMPROVEMENT - MEDIUM — The new API had no legacy delegates — fixed

`compat/billing.ex` gained nothing for `trash_order`, `restore_order`, `trash_invoice`,
`restore_invoice` or `record_payment_after_void`, and `list_invoices_for_order` stayed
at arity 1, while #64's review had added its entry point there. Added, plus
`mark_invoice_paid/2`, a pre-existing gap one line away. The drift test only checks the
shim's existing functions, so a new test pins these.

### NITPICK — V8's moduledoc understated what needs the columns — fixed

It said "the code that writes the columns needs them". The schemas select them, so
every read of an order or invoice fails without V8, which is the failure hosts would
actually meet. Reworded. **A release must say to run V8 before deploying.**

### Pre-existing — 80 msgids were in the code but not in the `.pot` — fixed

A real `mix gettext.extract` showed 80 strings in `lib/` that the hand-kept `.pot`
lacked, mostly the `Errors` catalogue, so they rendered in English in every locale.
`pot_drift_test` guarded tab labels only. Almost none of it comes from this PR.

All 80, plus the seven flashes from #65's review, are now in the `.pot` and translated
into `ru`, `uk` and `et` using each catalogue's terms. `de` and `fr` stay partial by
design. Three things came out of the fix:

- **The guard.** `pot_drift_test.exs` now fails on a `gettext/1` call with no msgid, and
  `errors_test.exs` checks that real messages change under each locale. The scan was
  compared with a real extraction; it does not read the 32 heredoc msgids in
  `email_defaults.ex`, which are all in the `.pot`.
- **A wrong plural.** `subscription_types.html.heex` called `gettext/2` on a plural
  msgid, which always takes form 0 and read "Пробный период 5 день". It now uses
  `ngettext/4`, as the form page does.
- **A trap in the documented command.** A plain `mix gettext.merge` filled 20 of the new
  entries with translations of similar msgids and marked them fuzzy. `AGENTS.md` now
  says `--no-fuzzy`.

**These translations were not written by native speakers either.**

## What Was Done Well

- The lock-order section is rare and valuable documentation.
- `updated_at` is deliberately preserved, so feeds do not read a trash as an edit.
- A trashed record refuses every change on the locked row as well as on the struct.

## Verdict

Sound. Every finding sits around the feature rather than in its logic.
