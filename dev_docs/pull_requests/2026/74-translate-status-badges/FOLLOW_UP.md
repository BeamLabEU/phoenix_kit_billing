# PR #74 Follow-up

| Finding | Severity | Resolution |
|---|---|---|
| Atom statuses not localized, booleans rendered as labels, `@spec` missing `atom()` | BUG - MEDIUM | Fixed in `PrintDocument.status_label/1`, `OrderStatusBadge`, and `InvoiceStatusBadge`: explicit `nil` and `is_boolean` clauses return `""`, atom statuses normalize via `Atom.to_string/1` for both labels and badge classes, and `PrintDocument.status_label/1` spec widened to `String.t() \| atom() \| nil`. Covered in `status_badges_test.exs`. |
| Admin billing profiles list still used `String.capitalize(profile.type)` | IMPROVEMENT - MEDIUM | Extracted `BillingProfileFields.type_label/1` and wired it into both `UserBillingProfiles` and `BillingProfiles` (card and table views), removing duplicate `Routes` aliases. Covered in `status_badges_test.exs`. |
| `PotDriftTest` collapsed `msgctxt` entries and skipped `pgettext/2` | IMPROVEMENT - MEDIUM | Keyed `po_translations/1` by `{msgctxt, msgid}` and added a `pgettext/2` coverage check against `default.pot`. |
| `import Ecto.Query` placed between `alias` directives | NITPICK | Moved `import` above `alias` in `test/phoenix_kit_billing/web/user_billing_profiles_test.exs`. |
