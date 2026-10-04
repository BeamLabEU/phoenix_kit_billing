# Code Review: PR #46 — Markdown bodies, a line-items table and the billing layout group for billing emails

**Reviewed:** 2026-10-04
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/46
**Author:** timujinne
**Head SHA:** 23f0683
**Status:** Merged (5661297)

## Summary

The four financial emails (invoice, receipt, credit note, payment
confirmation) stop being plain-text defaults and become a `markdown` part
(button, escaped line-items table, company footer) plus a separate `text` part,
sent in core's `billing` layout group and in the customer's own locale. New
public `PhoenixKitBilling.email_send_opts/4` is the one place that builds the
send options; `EmailDefaults` gains `defaults_for/2` (leaves out the button,
bank section and blank company lines), `line_items_table_html/2` and a preview
catalogue behind the new `email_templates/0` callback. The `phoenix_kit` floor
rises from 2.38.0 to 2.44.0.

## Verification

- Read the producing code in core 2.52.1 (`Mailer.send_from_template/4`,
  `Email.Content`, `Email.Markdown`, `Utils.RecipientLocale`) instead of the
  PR's description:
  - `:defaults` (zero-arity), `:layout` and `:locale` all reach `Content.resolve/5`;
    `delivery_opts/3` drops `:defaults`/`:layout`/`:paths` and keeps `:locale`,
    which is harmless.
  - A paragraph that is exactly one `{{{variable}}}` is emitted without a `<p>`
    (the way the table is placed); an empty `line_items_table_html` is left out
    by `defaults_for/2` and would be dropped by core's blank-paragraph rule anyway.
  - Variables are escaped by core's substitution after rendering, and `javascript:`
    link targets are dropped, so `refund_reason` / `user_name` cannot inject markup
    through the Markdown. The only raw values are the two line-items fragments,
    which billing now escapes itself.
  - `RecipientLocale.preferred/1` returns `nil` for a guest payer (no user), so a
    guest invoice is sent in the site's language — correct, there is no preference.
- Floor 2.44.0 matches core's changelog: `markdown` parts, layout groups and
  `email_templates/0` all shipped there.
- `line_items_html/1` (legacy bare `<tr>` rows) used to interpolate item names
  and descriptions unescaped; it is now escaped. That is a behaviour change for
  database templates, and the right one — a line-item name is operator or
  customer text.
- et/ru `.po` placeholders checked mechanically against their msgids
  (`{{…}}`, `{{{…}}}`, `%{…}`): no mismatch, nothing untranslated, nothing fuzzy.
- `mix test` against the local Postgres: 661 tests, 0 failures, 4 skipped (the
  documented subscription chain gap).

## Findings

No `BUG` found. Everything below is on record rather than fixed, with the reason.

### IMPROVEMENT - MEDIUM — The plain-text bodies do not leave out empty sections (not fixed)

`defaults_for/2` drops the bank-transfer section, the VAT line and the button
from the **Markdown** when the send has no value for them, but the `text`
defaults are single msgids, so an invoice without an IBAN still reads
`BANK TRANSFER DETAILS / Bank: / IBAN: / SWIFT/BIC:` and every text body prints
`VAT: ` for a company with no VAT number. The two versions of one email
therefore disagree. The text copy existed before this PR (nothing regressed),
and fixing it means splitting each text msgid into per-section msgids and
re-translating them in `et` and `ru`, which is a translation churn of its own;
worth doing as a follow-up if operators report it.

### IMPROVEMENT - MEDIUM — Dates in the emails are English whatever the locale (not fixed)

`format_date/1` is `Calendar.strftime(date, "%B %d, %Y")`, so an `et`/`ru`
customer gets a translated email with `October 16, 2026` in it. Pre-existing and
independent of this PR, but this PR is what makes the rest of the email follow
the customer's language, so the English month is now conspicuous. Needs core's
localized-date helper (as `user_orders.ex` already uses for the web side) — a
separate change.

### NITPICK — Blank `bank_name` / `bank_swift` still print an empty label

The bank section is gated on `bank_iban` only; an IBAN with no SWIFT shows
`SWIFT/BIC: `. Core's blank-paragraph rule covers only top-level paragraphs, not
list items. Rare (an IBAN normally comes with a BIC), left as-is.

### NITPICK — A nil `due_date` reads "Please pay it by -."

`format_date(nil)` is `"-"`. Invoices always get a due date at generation, so this
is only reachable through hand-edited data.

### NITPICK — Billing's own copy follows the customer's language only on core ≥ 2.48.0

Recipient-locale installation for a module's own Gettext backend (core #892)
shipped in 2.48.0; the floor is 2.44.0. On 2.44–2.47 the mail still sends
correctly, in the caller's locale, exactly as before this PR. The test helper
probes this by behaviour and excludes the dependent tests, and the README says
so; raising the floor to 2.48.0 would only add a hard requirement for no
functional gain.

### NITPICK — Hosts that override only `text.txt` lose the table on core ≥ 2.52.0

From 2.52.0 a host `text` outranks a module's `markdown` for the HTML body, so
such a host's HTML is its text escaped into paragraphs. This is documented in
`EmailDefaults`' moduledoc and the README (with the `html.html` /
`markdown.md` + `text.txt` workarounds); no code change possible on this side.

## Release note

The floor bump (`>= 2.44.0`) is consumer-facing: hosts on core 2.38–2.43 stay on
billing 0.18.x. The release's CHANGELOG entry flags it the way 0.18.0 did.

## Gate

`mix precommit` clean (dialyzer: 2 known warnings, both filtered by the ignore
file); `mix test`: 661 tests, 0 failures, 4 skipped.
