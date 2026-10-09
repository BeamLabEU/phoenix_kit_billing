# Code Review: PR #48 — Translate the printable billing documents and brand them

**Reviewed:** 2026-10-09
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/48
**Author:** timujinne (Tymofii Shapovalov)
**Head SHA:** 24da9f2
**Status:** Draft — REQUEST CHANGES

## Summary

The four print views (invoice, receipt, credit note, payment confirmation)
move their shared parts into `Web.Components.PrintDocument` (logo bar, seller
and customer blocks, footer, print controls, dates, statuses, payment
methods). Every label goes through `PhoenixKitBilling.Gettext` (en/et/ru),
dates use a translatable pattern with genitive month names, and `<html lang>`
follows the locale. The invoice's swapped parties are fixed (seller under
From, customer under Bill To). `format_company_address/1` writes UA/RU/BY/KZ
addresses postal-code-first on one line and names the country in the reader's
language; it is now used for the customer too. The seller block gains the
registration number; the invoice's bank block gains the account holder and
drops empty rows.

New `PhoenixKitBilling.DocumentBranding` reads two settings,
`billing_document_logo_file_uuid` (media-library file, falling back to
`auth_logo_file_uuid`, then the company name) and `billing_document_footer`.
They are edited in a new "Printed Documents" card under Billing → Settings,
and saving needs `manage_settings`. The four financial emails carry the
footer (`document_footer` for the text body, an escaped `document_footer_html`
paragraph for the HTML body) and, for a PNG/JPEG/GIF billing logo outside a
private library, a `logo_url` that replaces the site logo in the layout
header. The company address in emails is formatted in the recipient's locale.
The new core calls are declared in `CoreCompat`, and AGENTS.md lists the
settings.

The structure is sound. The extraction removes about 700 lines of
copy-pasted markup, the escaping is right on every path, and hosts without
the new settings keep working. One confirmed bug in the settings save path
and one data-loss trap in the new form need fixing before merge.

## Verification

- **Suite:** `MIX_ENV=test PGDATABASE=pkbill_test_domovych_uk PGPOOL=10 mix test`
  in the PR worktree gives 702 tests, 0 failures, 4 skipped (the documented
  subscription chain gap).
- **Gate:** `compile --warnings-as-errors`, `format --check-formatted`,
  `credo --strict` and `dialyzer` are clean. I ran them in a scratch copy of
  the worktree; dialyzer shows only the 2 known warnings, both skipped by the
  ignore file.
- **CHANGELOG and @version:** `git diff upstream/main...HEAD --name-only`
  touches neither `CHANGELOG.md` nor `mix.exs`. All 5 commits are authored by
  the owner, with no tool trailers.
- **Gettext:**
  - I ran `mix gettext.extract` in the scratch copy and compared it against the
    PR's `default.pot`. Every msgid the PR adds (and its `msgctxt` "date",
    "invoice status", "receipt status") is in the `.pot`.
  - en/et/ru have no empty and no fuzzy entries. `%{…}` / `{{…}}` placeholders
    match their msgids in all three locales.
  - No existing translation was changed. `pot_drift_test` passes.
  - The `.pot` lags the code by about 80 msgids in files this PR does not touch
    (errors, permissions, email bodies). That drift was already on upstream
    and is not from this PR.
- **Core API at the floor:** I checked each new call against the core
  checkout's tags. `Storage.get_file/1`, `URLSigner.signed_url/2,3` (with
  `version:`), `Routes.base_url/0`, `Storage.Libraries.private_file?/1`,
  `UploadsParentFolder`, and `MediaSelectorModal`'s `lock_file_type` and
  server-side `selectable?/2` all exist in **v2.44.0**, the floor.
- **Authorization:**
  - `save_documents` goes through `Authz.authorize(:manage_settings)`.
  - The other three new handlers (`open_document_logo_selector`,
    `clear_document_logo`, `{:media_selected, _}`) only change assigns.
  - A forged event therefore cannot persist anything without the permission;
    `settings_documents_test` covers the footer side of this.
  - Core caches the tab's `billing.manage_settings` as the view's permission
    (`Registry.auto_register_custom_permission/1`, sub-key branch, present
    from 2.44.0). So on every supported core the page is not even mountable
    without it.
- **Logo safety:**
  - The logo uuid comes only from the picker. Core's picker re-checks every
    uuid the browser sends (`selectable?/2`: live, not system-managed, not in
    a private library, image type when `lock_file_type`).
  - The printed URL carries the permanent token. The file route refuses that
    token for a private-library file, so a private file cannot leak through
    the documents; it shows as a broken image.
  - The email skips private files and non-mail-safe types.
- **Footer escaping:**
  - Print: HEEx-escaped, with `white-space: pre-line`.
  - Email: I rendered an invoice email end to end through
    `PhoenixKit.Email.Content.resolve/5` in a scratch test, with the footer
    `«Acme» <b>bold</b> & Co\r\nLine 2 {{user_email}}`.
  - The HTML body gets
    `<p style="…">«Acme» &lt;b&gt;bold&lt;/b&gt; &amp; Co<br>Line 2 {{user_email}}</p>`:
    escaped, the line break kept, no nested `<p>`, and no second substitution
    of `{{user_email}}`.
  - The text body carries the footer verbatim, inside the company box.
  - The layout header shows the billing logo as an absolute URL.
- **Parties:**
  - Only the invoice had them swapped; it is fixed.
  - Receipt and payment confirmation keep "Received By" = seller and
    "Received From" = customer. Only the column order changed, seller now
    first.
  - Credit note keeps "Issued By (Payer)" = seller.
  - The emails were already right (`Bill To: {{user_name}}`).
- **Address format:**
  - The non-postal-first branch produces exactly the old lines (street, line 2,
    "City Postal", state, country), so EU/US output is unchanged apart from
    the translated country name.
  - The postal-first order for UA/RU/BY/KZ matches the register convention
    (ЄДР / ЕГРЮЛ: "36007, Полтавська обл., м. Полтава, вул. …").
  - Blank and `nil` parts are dropped, and an unknown code prints as itself.
- **Backward compatibility:**
  - A host with no new settings gets the project logo, or the company name, in
    a new top band.
  - The footer no longer repeats the address and VAT; VAT stays in the seller
    block.
  - Emails gain nothing: no footer paragraph, and no `logo_url`, so core keeps
    the site logo.
- **Screenshots** (`/tmp/pw/shots/invoice-*.png`): checked the invoice (screen
  and print media), receipt, email and settings card. The layout holds with
  the longer Ukrainian labels.

## Findings

### BUG - MEDIUM — A footer longer than 1000 characters is silently discarded, with a success flash (open)

`Web.Settings.gated_event("save_documents", …)`
(`lib/phoenix_kit_billing/web/settings.ex:245-257`) ignores both
`Settings.update_setting/2` results. Core's `Setting` changeset validates
`value` to at most 1000 characters (`validate_setting_value/1`, every
non-optional key). A longer footer therefore returns `{:error, changeset}`.
The LiveView still flashes "Document settings saved", and `load_settings/1`
then reloads the old text into the textarea. The operator's text is gone and
they are told it was saved.

Reproduced in a scratch LiveView test: with a 1,120-character footer
submitted, the success flash is shown, the stored value is still
"Old footer", and a direct `update_setting` returns `:error`. The two writes
are also not atomic: the logo can save while the footer fails.

**Fix:**
- Check both results. On error, keep the submitted text in the assign and
  flash an error.
- Add `maxlength="1000"` to the textarea.
- Optionally note the limit in the help text and in AGENTS.md.

A test with a >1000-character footer should assert the error flash and that
the submitted text survives.

### IMPROVEMENT - MEDIUM — Unsaved form state is wiped by the card's own controls (open)

The documents form (`settings.html.heex:257`) has no `phx-change`, so the
server never learns what was typed in the footer textarea (`:297`).

**Lost footer text.** Any round trip that changes an assign re-renders the
form: "Select Image", "Remove", picking a file in the modal, "Save General
Settings", or the tax-rate change event. LiveView 1.2.12's DOM patch then
morphs the non-focused textarea back to the server's `@document_footer`.
This is the `dom_patch` `onBeforeElUpdated` → morphdom `TEXTAREA` handler;
only the focused input is preserved. The natural flow loses the text: type
the footer, then click "Select Image". This follows from the patch code; I
did not click through it in a browser.

**Lost logo pick.** The reverse also happens. A picked but unsaved logo lives
only in `@document_logo_uuid`. "Save General Settings" calls `load_settings/1`,
which reloads it from the database, and the pick silently disappears. The
preview had shown it as set.

No form recovery on reconnect follows from the same cause.

**Fix:** add `phx-change="change_documents"`, keeping `document_footer` in an
assign (it can stay ungated, since it writes nothing). Alternatively, persist
the logo on pick (gated) and keep the footer in an assign.

### IMPROVEMENT - MEDIUM — `MediaSelectorModal` is core API the inventory does not list (open)

`settings.html.heex:319` mounts `PhoenixKitWeb.Live.Components.MediaSelectorModal`.
It relies on the `lock_file_type` / `file_type_filter` attrs and on its
message contract (`{:media_selected, uuids}`, `{:media_selector_closed}`,
`settings.ex:272-283`).

It is a module reference inside a template, not a call. Neither the AST
extractor nor `compile_time_modules/0` sees it, and a core that moves or
renames it breaks the picker only at click time. AGENTS.md calls `CoreCompat`
"the inventory of what core owes this package".

**Fix:** declare it, for example `{PhoenixKitWeb.Live.Components.MediaSelectorModal, :update, 2}`
in `runtime_calls/0` with a comment naming the message contract, or extend
`compile_time_modules/0`.

### IMPROVEMENT - MEDIUM — The email logo is the full-size original, unversioned (open)

`DocumentBranding.email_logo_url/0` (`document_branding.ex:120-128`) always
serves the `"original"` variant (`@logo_variant`, `:36`) with no `version:`.
Core's own email logo (`PhoenixKit.Email.Branding.public_logo_url/1`) picks
the first finished mail-safe variant, small → medium → large → original, and
mints a versioned URL.

A 3000-px, multi-megabyte PNG uploaded as the billing logo is downloaded in
full by every recipient for a 40-px header. An edited image keeps the same
URL and relies on revalidation.

Everything needed exists at the floor (`Storage.list_file_instances/1`,
`URLSigner.signed_url/3` with `version:`). The original is the right file
for print, so only the email path needs this.

### NITPICK — The picker opens without the `manage_settings` check

`open_document_logo_selector` (`settings.ex:101-104`) is ungated, and the
modal it opens can browse the whole site library and **upload** files into
storage. Every supported core mount-gates this page on `billing.manage_settings`,
so this is defence in depth only. AGENTS.md's convention is that bundled-UI
handlers re-check the capability, though, and the page's own test mounts it
with base `"billing"` alone.

**Fix:** wrap the handler in `Authz.authorize(socket, :manage_settings, …)`.

Related parity point: core's branding picker passes
`scope_folder_id: PhoenixKit.UploadsParentFolder.resolve(:branding, Actor.uuid(socket), nil)`.
Billing does not, so on a host with that hook a billing logo upload lands at
the root. The hook exists at the floor.

### NITPICK — `Libraries.private_file?/1` is not "later than the floor"

The comment at `document_branding.ex:145` says libraries arrived after this
module's floor, and `CoreCompat` lists the function under `optional_calls`.
`PhoenixKit.Modules.Storage.Libraries.private_file?/1` is in core v2.44.0.
The guard is harmless, but the comment and the list placement say something
untrue. Either move it to `runtime_calls/0` and call it directly, or reword
the comment as defensive.

### NITPICK — A bare "From" msgid translated as "Поставщик" / "Müüja"

`invoice_print.html.heex:433` uses `gettext("From")`, which ru translates as
"Поставщик" and et as "Müüja". It is the only use today, but the next
`gettext("From")` (a date-range filter, say) inherits "supplier".

**Fix:** use `pgettext("document party", "From")` (and the same for
"Bill To"), as the PR already does for statuses and months.

### NITPICK — The footer paragraph style is duplicated

The preview sample at `email_defaults.ex:355` hard-codes the same inline
style as `DocumentBranding`'s private `@footer_style`. A style change in one
place leaves the preview stale. Build the sample through the same function,
or expose the style.

### NITPICK — `save_documents` crashes on a non-string footer param

`String.trim(params["document_footer"] || "")` (`settings.ex:250`) raises
`FunctionClauseError` for a forged map or list value. Only a
`manage_settings` holder can reach it, and only their own LiveView restarts.
`case params["document_footer"] do text when is_binary(text) -> … end` closes
it.

### NITPICK — An empty logo band when there is neither logo nor company name

`PrintDocument.brand/1` (`print_document.ex:96-106`) always renders the band,
which has `min-height: 56px` plus padding. With no logo and an empty company
name, every document opens with roughly 100 px of blank white.
`:if={@logo_url || @company.name != ""}` avoids it.

### NITPICK — The logo lookup accepts files the file route will not serve

`logo_file/1` (`document_branding.ex:130-143`) checks only `trashed_at`.
Core's file route also refuses `system_managed` files, and refuses a private
file's permanent token. A private **project** logo, reachable through the
`auth_logo_file_uuid` fallback, therefore prints as a broken image instead of
the company name. Rare; mirroring `servable_file/2` plus the email path's
`private_file?/1` check would make print fail over to the name the way email
does.

### NITPICK — The base-locale split is written three times

`PrintDocument.html_lang/0`, `PhoenixKitBilling.base_locale/1` and
`translated_country_name/1` each do `String.split(["-", "_"]) |> hd()`. One
helper would do.

### NITPICK — README's Settings table does not list the new keys

AGENTS.md documents `billing_document_logo_file_uuid` and
`billing_document_footer`, but README's host-facing Settings table does not.
That table is also stale in other ways: `billing_default_currency` is dead.

## Observations (pre-existing, not regressions; for follow-ups)

- **HTML emails flatten the company address.** `{{company_address}}` sits
  inside a `<p>`, so its `\n`s collapse ("Kyiv Ukraine" on one line in the
  scratch render). The PR fixed exactly this for the footer text; the address
  could get the same `<br>` treatment.
- **Email dates are still English** ("Invoice date: Oct 09, 2026."), while
  the print documents are now localized. This was flagged in #46;
  `PrintDocument.format_date/1` could now serve the emails too.
- **Print times are UTC with no zone** (`format_datetime/1`, "08:17" for an
  11:17 Kyiv payment).
- **The street-first order is wrong for most of the EU.** It writes
  "City Postal", but EE/DE/FR write "10117 Tallinn", and the US writes
  "City, ST 12345". The new test and the `format_company_address/1` doc
  example pin "Tallinn 10117" as the expected form.
- **A company customer prints only its VAT number.** The snapshot also has
  `company_registration_number` (the buyer's ЄДРПОУ on a UA B2B invoice),
  which would mirror the seller's new "Reg. No:".
- **The receipt's "Payment Method" is hard-coded to bank transfer**, whatever
  the provider.
- **The footer is one text for every locale**, so an et/ru document carries
  it in the language it was typed in. This is by design, but worth a line in
  the help text.

## Tests

The new tests check behaviour, not markup:
- the Russian/English invoice by element ids;
- the parties under the right headings;
- the bank rows;
- the localized date;
- the footer;
- the receipt, credit note and payment confirmation titles;
- `DocumentBranding` fallbacks (trashed, missing, non-uuid, SVG for email);
- the settings save and its permission gate;
- address formatting for UA, EE and unknown codes.

Gaps worth filling with the fixes:
- a >1000-character footer;
- an end-to-end email render with footer and logo through `Content.resolve/5`
  (I did it as a scratch test, and it passes);
- RU/BY/KZ postal-first;
- the email's private-library exclusion;
- the permission gate on the logo.

## Verdict

**REQUEST CHANGES.** No security problem: authorization, escaping and
private-file handling are all correct, and the CHANGELOG / `@version`
constraint is respected.

Before merge:
1. Fix the silent loss of a >1000-character footer (BUG - MEDIUM).
2. Stop the form's own controls wiping unsaved footer text and logo picks
   (IMPROVEMENT - MEDIUM).

The CoreCompat entry for `MediaSelectorModal` and the email-sized logo are
cheap and worth taking in the same round. The nitpicks are optional.
