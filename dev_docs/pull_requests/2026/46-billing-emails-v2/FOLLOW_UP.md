# PR #46 follow-up

**Date:** 2026-10-04  
**Implemented by:** Codex

| Finding | Resolution |
|---|---|
| Claude: plain-text bodies retain empty bank/VAT sections | Split translated text into sections; both formats now omit absent bank details, company details and document links. Updated en/et/ru catalogues. |
| Claude: email dates are English in every locale | Format every date in the recipient's locale with core's translated month helper; previews use the same formatter. |
| Claude: absent bank name/SWIFT prints an empty label | Gate those lines independently in both formats while retaining the IBAN and invoice reference. |
| Claude: nil due date reads “Please pay it by -.” | Return an empty missing date and omit payment deadline copy in both formats. |
| Claude: billing copy follows the recipient only on core >= 2.48.0 | Install billing's backend locale explicitly in send/preview defaults; remove the conditional locale-test exclusion. Required APIs exist in core 2.44.0. |
| Codex: an explicit billing backend locale can override the recipient even on newer core | Override that backend only while evaluating the defaults callback, then restore the sender's locale. |
| Claude: a text-only host override changes HTML on core >= 2.52.0 | Retain the documented host override instructions; core owns this priority. |

Validation: full suite **669 tests, 0 failures, 4 known skips**; `mix precommit`
passed. Focused email tests also passed with core 2.44.0's recipient-locale
implementation. Release 0.19.0's published files match its tag. No new release
was published as part of this follow-up.

See [CODEX_REVIEW.md](CODEX_REVIEW.md) for triggers, fixes and validation limits.
