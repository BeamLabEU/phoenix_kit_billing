# Code Review: PR #50 — Share the billing profile form fields between dashboard, admin and other callers

**Reviewed:** 2026-10-10 (post-merge)
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/50
**Author:** timujinne (Tymofii Shapovalov)
**Merge:** e9ff629

## Summary

The dashboard form (~340 lines of hand-written markup) and the admin form each
carried their own copy of the billing profile fields. They now render
`Web.Components.BillingProfileFields.billing_profile_fields/1`, built on core's
`<.input>`, `<.select>`, `<.textarea>` and `<.checkbox>`, with a `type`/`id_prefix`/
`require_*`/`show_options` surface so the e-commerce checkout can reuse it.
`BillingProfile` gains `fields_changeset/3` (the user-facing field rules without
owner or `is_default`) and `form_fields/0`; `changeset/2` is now `fields_changeset`
plus owner, default and metadata. Field lengths mirror the column sizes and count
code points, over-long display names are cut instead of raising, validation
messages go through gettext, and `de`/`fr` catalogues are added for the shared form.

This also finishes the "component migration tail" item for the billing profile
form in AGENTS.md.

## Verification

- `mix test`: 816 tests, 0 failures, 4 skipped.
- Column sizes in `@max_lengths` match core's V135 `phoenix_kit_billing_profiles`
  (`name`/`first_name`/`last_name`/`middle_name`/`phone`/`email`/`company_name`/
  `address_line1`/`address_line2`/`city`/`state` 255, `company_vat_number` 20,
  `company_registration_number` 30, `postal_code` 20, `country` 2,
  `company_legal_address` text, so correctly uncapped).
- Catalogues: a script over `priv/gettext/*/default.po` finds no fuzzy entries and
  no placeholder (`%{…}` / `{{…}}`) mismatches in any locale. `et`/`ru`/`uk`/`en`
  translate all 776 entries; `de`/`fr` translate 46 and leave the rest empty, which
  falls back to the msgid, as AGENTS.md states. Plural-Forms headers are correct.
- `save` in both forms still forces `type` from the `profile_type` assign, so the
  radios now being named `billing_profile[type]` (they used to be `profile_type`,
  outside the params) cannot disagree with it.
- Locale: core's `Auth` puts the locale on the process-global Gettext as well as
  its own backend, so the new translated validation messages follow the request in
  billing's own LiveViews. The component documents the extra `put_locale` call a
  caller outside them needs.

## Findings

### IMPROVEMENT - MEDIUM — A blank country silently becomes "EE" in the bundled forms (not fixed)

`BillingProfile.changeset(%BillingProfile{country: "LV"}, %{"country" => ""})`
yields `country: "EE"` and a valid changeset (checked): Ecto replaces a blank
param with the schema default. Both bundled forms go through `changeset/2`, so
picking "Select country..." on an existing Latvian profile saves Estonia without
an error. `fields_changeset/3` fixes it behind `require_address: true`, and the
PR's tests pin the old behaviour for `changeset/2` on purpose, but the dashboard
form used to label the field "Country *" and now shows no marker at all.

Not fixed here: tightening `changeset/2` changes what every context caller gets
for a blank country (checkout, imports), which is a decision for the maintainer.
Suggested fix: have the two bundled forms validate and save with
`require_address: true` (thread the option through `change_billing_profile/3`), or
drop the blank option from the select once a country is chosen.

### NITPICK — The type radios fire two events per click

The radios carry `phx-click={@type_event}` and are now also form inputs named
`billing_profile[type]`, so a click sends `change_type` and a form `validate`. The
component's moduledoc says so, and both handlers are idempotent. Noted only so a
caller with a non-idempotent `type_event` is not surprised.

### NITPICK — `maybe_set_display_name/1` cuts by code point

`String.codepoints/1 |> Enum.take(255)` can split a grapheme (a base letter from
its combining accent) at the cut. The column counts code points, so the cut is
correct for Postgres; the effect is a cosmetic accent loss on a 255-character
name. Not worth a grapheme-aware pass.

### NITPICK — AGENTS.md line was 150+ characters (fixed)

The gettext bullet's catalogue list was appended to one long line. Reflowed.

## Verdict

Approve. One improvement recorded for the maintainer, one nitpick fixed.
