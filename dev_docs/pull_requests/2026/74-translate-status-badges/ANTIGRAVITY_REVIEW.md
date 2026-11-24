# PR #74 — Translate the order and invoice status badges and the billing profile type

**Author:** timujinne (`63ad95b`) · **Reviewed:** 2026-11-24

Translates `OrderStatusBadge` (via `pgettext("order status", ...)`), `InvoiceStatusBadge` (via `PrintDocument.status_label/1` / `pgettext("invoice status", ...)`), and the billing profile type badge (`Individual` / `Company`), adds `Order.statuses/0` and `Invoice.statuses/0`, updates the `.pot` and all six locale `.po` files (`en`, `et`, `ru`, `uk`, `de`, `fr`), and adds unit and LiveView tests.

**Verdict:** Merged with follow-up fixes and improvements.

## Findings

### BUG - MEDIUM: Atom statuses not localized and booleans rendered as status labels

- **Files:** `lib/phoenix_kit_billing/web/components/print_document.ex`, `lib/phoenix_kit_billing/web/components/order_status_badge.ex`, `lib/phoenix_kit_billing/web/components/invoice_status_badge.ex`
- **Issue:**
  - `PrintDocument.status_label/1` and `OrderStatusBadge.format_status/1` handled `when is_binary(status) or is_atom(status)` with `status |> to_string() |> String.capitalize()`.
  - `nil` only returned `""` via the `to_string(nil) == ""` side effect; booleans (`true` / `false`) rendered as `"True"` / `"False"`.
  - Known atom statuses (e.g. `:paid`) fell back to English `"Paid"` instead of translating in non-English locales, and `status_class/1` in both badges gave them `"badge-ghost"` instead of the matching color class.
- **Fix:** Match `nil` and `is_boolean(status)` explicitly to `""`, normalize non-nil/non-boolean atoms via `Atom.to_string/1` before label and class lookup, and widen `@spec status_label(String.t() | atom() | nil) :: String.t()` on `PrintDocument.status_label/1`.

### IMPROVEMENT - MEDIUM: Admin billing profiles list still used `String.capitalize(profile.type)`

- **Files:** `lib/phoenix_kit_billing/web/billing_profiles.html.heex`, `lib/phoenix_kit_billing/web/billing_profiles.ex`, `lib/phoenix_kit_billing/web/user_billing_profiles.ex`, `lib/phoenix_kit_billing/web/components/billing_profile_fields.ex`
- **Issue:** While the customer billing profiles list translated `"individual"` / `"company"`, both the card header and table cell on the admin billing profiles page still rendered `String.capitalize(profile.type)` right below the already-translated filter dropdown.
- **Fix:** Extracted `BillingProfileFields.type_label/1` (using the existing `"Individual"` / `"Company"` msgids with safe handling for `nil`, booleans, atoms, and unknown values) and used it in both `UserBillingProfiles` and `BillingProfiles`. Also removed the pre-existing duplicate `alias PhoenixKit.Utils.Routes` in both LiveViews.

### IMPROVEMENT - MEDIUM: `PotDriftTest` did not distinguish `msgctxt` entries or guard `pgettext/2`

- **File:** `test/phoenix_kit_billing/pot_drift_test.exs`
- **Issue:** `po_translations/1` keyed its map only by `msgid`, so contextual entries (`"order status"`, `"invoice status"`, `"receipt status"`, `"date"`, `"document party"`) collided with and overwrote plain entries of the same `msgid` (e.g. `"Paid"`, `"Draft"`, `"Refunded"`). Additionally, `pgettext/2` calls in `lib/` were not checked against `default.pot`.
- **Fix:** Key `po_translations/1` by `{msgctxt, msgid}`, restrict `pot_msgids/1` to `msgctxt: nil`, and add a `pgettext/2` `{context, msgid}` coverage check against `default.pot`.

### NITPICK: Import/alias ordering in `user_billing_profiles_test.exs`

- **File:** `test/phoenix_kit_billing/web/user_billing_profiles_test.exs`
- **Issue:** `import Ecto.Query, only: [from: 2]` was placed between two `alias` lines.
- **Fix:** Moved `import` above `alias`.

## Checked, fine

- All six `order status` entries are present in `priv/gettext/default.pot` and all six locale `.po` files (`en`, `et`, `ru`, `uk`, `de`, `fr`) with no fuzzy flags and consistent grammatical agreement (`fr` feminine for both orders and invoices; `ru` masculine for orders; `uk` neuter for orders; `de`/`et` accurate).
- Plain `fr` `"Paid"` remains `"Payé"` (correct for amount labels) and plain `de`/`fr` `"Cancelled"` remains untouched for subscription pages.
- `Order.statuses/0` and `Invoice.statuses/0` return `@valid_statuses` directly with `@doc` and `@spec`, keeping test coverage locked to the schema lists.

## Validation

- `mix precommit` (`compile --force --warnings-as-errors`, `deps.unlock --check-unused`, `mix hex.audit`, `format --check-formatted`, `credo --strict`, `dialyzer`) — passed, 0 issues.
- `mix test` (with `phoenix_kit_billing_test` database) — 1699 tests, 0 failures, 0 excluded.
