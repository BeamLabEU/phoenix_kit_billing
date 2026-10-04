# Code Review: PR #46 and release 0.19.0

**Reviewed:** 2026-10-04  
**Reviewer:** Codex  
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/46  
**Merge:** `5661297ccfd967a98de29f8858aa37cb093b3e89`  
**Released commit:** `1fab0fb760cc86e370f98b80c8278399f4c2948f`  
**Scope:** Independent review of the release, Claude's findings, email content,
variable builders, locale handling, rendering, translations and core contracts.

## Result

Found and fixed one medium locale bug and both medium improvements in Claude's
report. Also fixed missing bank labels, missing plain-text links and missing due
dates. No critical or high finding. The changes are a follow-up to the existing
release; this review does not publish a new version.

## Findings

### BUG - MEDIUM — Defaults can use the sender's language

`email_send_opts/4` passed a recipient locale, but its defaults callback relied
entirely on core to install that locale. Core 2.44–2.47 installs only its own
Gettext backend. Even core 2.52.1 preserves an explicitly set
`PhoenixKitBilling.Gettext` locale. With the billing backend set to English and
the customer preferring Estonian, the callback consequently returns English
copy. The same problem affects a preview when its process has a billing backend
locale already installed.

**Fix:** Resolve the user's preference or site language explicitly, keep the full
dialect for host file lookup, and wrap the deferred defaults callback in
`Gettext.with_locale/3` for billing's backend using the normalized base language.
Preview defaults use the locale core installs for its own backend. Both wrappers
restore the caller's locale. Locale tests no longer need the older-core
exclusion in `test_helper.exs`.

**Evidence:** A regression test failed before the fix. Tests cover an explicit
sender backend locale, dialects and underscore/case normalization. The focused
suite also passes after loading the actual recipient-locale implementation from
the published core 2.44.0 package into an isolated test VM.

### IMPROVEMENT - MEDIUM — Plain text retains blank sections

Confirmed Claude's finding: the plain-text bodies were full-body translations,
so omitting sections from Markdown still left empty bank details, VAT labels and
document links in plain text.

**Fix:** Split the text into translated sections and apply presence checks to
both bodies. Bank details require an IBAN; bank names and SWIFT codes are
independently optional. Company details use the same presence rules in both
formats. A missing link removes both the HTML button and the plain-text link.
Empty item lists omit the plain-text item section. The payment confirmation's
text footer now includes VAT when present, matching its HTML footer.

The hand-maintained POT and all three PO catalogues were updated. Existing
Estonian and Russian section translations were reused; the two newly separated
invoice sentences were translated. No fuzzy or empty translations remain.

### IMPROVEMENT - MEDIUM — Dates ignore the recipient's language

Confirmed Claude's finding: `Calendar.strftime(date, "%B %d, %Y")` always uses
English month names. The variables were also assembled before core entered the
recipient's locale, so simply replacing that function with a localized helper
would still use the sender's language.

**Fix:** Build each date in `RecipientLocale.in_locale/2`, resolved from the
customer or site language. Use the existing `Utils.Date.short_month/1` helper
and the ordering used on billing's customer order page. Preview sample dates use
the same formatter. Examples are `Oct 16, 2026`, `16 Okt 2026` and
`16 Окт 2026`. Updated `CoreCompat` alongside the changed core calls.

All required helpers exist in the published core 2.44.0 source, so the dependency
floor remains unchanged. Tests cover every date variable in all four builders,
Date/DateTime/NaiveDateTime inputs, sender-locale restoration and previews.

### NITPICK — A missing due date prints a fabricated deadline

The previous nil formatter returned `"-"`, producing “Please pay it by -.” and
plain-text deadline labels containing a dash.

**Fix:** A missing date is empty. An absent due date omits the payment request
and plain-text deadline lines. Ordinary invoices retain their deadline.

## Release integrity

- Hex's 0.19.0 release exists, is not retired, and declares the advertised core
  requirement `>= 2.44.0 and < 3.0.0`.
- All **119 files** extracted from its published tarball match their blobs at
  the `0.19.0` git tag exactly.
- Remote main and the peeled annotated tag both identify the released commit
  `1fab0fb760cc86e370f98b80c8278399f4c2948f` at review time.
- The GitHub release exists at
  https://github.com/BeamLabEU/phoenix_kit_billing/releases/tag/0.19.0.

## Validation

- Full `mix test`: **669 tests, 0 failures, 4 skipped**. Skips are the documented
  subscription migration gap; no subscription changes were made.
- `mix precommit`: passed, including compilation with warnings as errors,
  unused-lock check, Hex audit, formatting, strict Credo and Dialyzer. Dialyzer
  reports only the two existing warnings covered by the ignore file.
- Focused email/core-contract suite: **61 tests, 0 failures**.
- Focused email suite with core 2.44.0's actual `RecipientLocale` module loaded:
  **55 tests, 0 failures**. This checks the older locale semantics, not the full
  suite against every dependency from that core release.
- Translation audit: **675 active messages per catalogue**, matching the POT,
  with no duplicate messages, fuzzy flags, empty translations or mismatched
  substitution placeholders.

## Remaining constraints

Host database/file templates retain core's resolution priority. In particular,
the documented core 2.52 text-only override behavior is still controlled by
core; hosts wanting a customized HTML table must provide an HTML or Markdown
override. Customer/operator-supplied descriptions and payment terms remain
their supplied text. Review did not perform real email delivery through
`phoenix_kit_emails`, which is deliberately absent from this test suite.
