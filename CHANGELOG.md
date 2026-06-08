# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.5.1] - 2026-06-08

No consumer-facing changes — the published surface (declared `{:phoenix_kit, "~> 1.7"}` and behaviour) is identical to 0.5.0. This release refreshes dependencies and adds local-development tooling.

### Changed
- **Dependencies refreshed** (`mix.lock`): `phoenix_kit` 1.7.131 → 1.7.133, plus transitive bumps (`bandit` 1.11.1 → 1.12.0, `req` 0.5.18 → 0.6.1, `tesla` 1.18.3 → 1.20.0, `etcher` 0.6.5 → 0.6.6, `fresco` 0.6.3 → 0.7.1, `spitfire` 0.3.12 → 0.3.13). No declared requirement changed; `mix.lock` is not part of the published package.

### Added
- **Local cross-repo development tooling.** A `pk_dep/3` helper in `mix.exs` lets `phoenix_kit*` deps resolve to a local checkout via `<APP>_PATH` (e.g. `PHOENIX_KIT_PATH=../phoenix_kit mix test`) without altering the published Hex pin — unset resolves exactly as before. An exported-but-empty var falls back to the published pin rather than building a broken `path: ""` dep. Documented in `AGENTS.md`.

## [0.5.0] - 2026-06-05

### Security
- **Payment-method ownership is now enforced in the context.** `create_subscription/2` and `update_subscription/2` reject a `payment_method_uuid` that isn't one of the subscription user's own *active* methods (`{:error, :payment_method_not_usable}`), instead of relying on the changeset's foreign-key check alone (which only proves the row exists). Previously the guard lived only in the admin `SubscriptionForm`, so any other caller could attach another user's or an inactive/removed payment method. The form retains a fast UX pre-check.

### Fixed
- **Subscription edit-save dropped payment-method changes.** Edit mode only ran `change_subscription_type/2`, and the payment-method selector was hidden behind `@live_action != :edit` so the field couldn't be changed at all. The selector now renders in edit mode and a changed `payment_method_uuid` is persisted via `update_subscription/2` (type changes still route through `change_subscription_type/2` so its broadcast fires).
- **`list_payment_methods/2` silently ignored the `status:` option.** Callers passing `status: "active"` worked only by the `active_only` default; `status:` was never inspected. It now honours an explicit `status:` (exact-status filter) with `active_only` (default `true`) as the fallback.
- **Invoice-less transaction rows** were `cursor-pointer` and navigated to a broken `/invoices/` URL; rows are now clickable only when an invoice exists.

### Changed
- `format_company_address/1` made pure — dropped the dead `company_info \\ nil` impure default (the argument is now required); the compat delegate's arity matches.
- `permission_metadata` billing icon `💰` → `hero-banknotes` to match the billing tabs.
- DRY'd the 13 `Tab.new!` calls behind a private `billing_tab!/1` helper.

### Tests
- Added `compat_delegate_test` (asserts every `compat/*.ex` delegate is `function_exported?` on its target at the same arity), `list_payment_methods/2` scoping and `status:`-filtering tests, and context-level payment-method guard reject-path tests (these short-circuit before any insert, so they run without the core `subscription_type_uuid` skip).

## [0.4.0] - 2026-06-04

### Added
- **Activity logging** (`PhoenixKitBilling.Activity`) — a guarded LiveView-layer wrapper around `PhoenixKit.Activity.log/1`, invoked on every admin mutation (orders, invoices, currencies, subscriptions, subscription types, billing profiles, and payment/refund/send actions). Logging failures never crash the caller, and only PII-safe metadata (uuids, status strings, amounts, currency codes, counts) is recorded.
- **Centralized error messages** (`PhoenixKitBilling.Errors`) — maps the error atoms returned by contexts, providers, and webhook handlers to gettext-backed, extractable human-readable strings. All admin flash/error messages now route through `Errors.message/1` instead of `inspect/1`, so users no longer see raw atoms like `:has_active_subscriptions`. Also formats `%Ecto.Changeset{}` reasons.
- **Webhook retry cap** — `WebhookProcessor` now stops reprocessing an event once `WebhookEvent.max_retries_exceeded?/1` is true (≥5 attempts) and the controller acknowledges it with HTTP 200 so providers stop redelivering an intentionally-abandoned event.
- Full DB + LiveView test harness (DataCase/LiveCase, test endpoint/router/layouts) and ~230 new tests across schemas, contexts, regressions, activity logging, and LiveView smoke/validation.

### Fixed
- **Webhook processing crashed on every event.** `upsert_webhook_event/1` used `Access` bracket syntax on a `%Providers.Types.WebhookEventData{}` struct (no `Access`), raising `UndefinedFunctionError` so the controller returned 400 and no event was ever processed. Now reads the field via `Map.get/2`.
- **Stripe was unreachable from the admin UI.** The UI saves the secret to `billing_stripe_secret_key` but `Stripe.get_config/0` read `billing_stripe_api_key`, so `available?/0` was always false and checkout returned `:provider_not_available`. Now reads `billing_stripe_secret_key` with a fallback to the legacy key, and `available?/0` always returns a boolean.
- **`unique_constraint` names didn't match the DB indexes** for `webhook_events`, `currencies`, `subscription_types`, and `payment_methods`, so duplicate inserts raised `Ecto.ConstraintError` instead of returning `{:error, changeset}`. For `WebhookEvent` this broke idempotency (a duplicate delivery surfaced as `:processing_error` instead of `:duplicate_event`). Names pinned to the actual indexes.
- **Receipts were never sent after a webhook payment.** The webhook path called `send_receipt/2` on an invoice without a `receipt_number` (the number is stamped only on the struct returned by `generate_receipt/1`), so it always returned `{:error, :receipt_not_generated}`. The processor now sends from the receipt-bearing struct.
- `extend_subscription` crashed (`FunctionClauseError`) when `current_period_end` was nil; it now reports a friendly error instead.
- `extend_subscription` now derives the extension from the subscription type's billing period rather than a hardcoded 30 days; `update_subscription/2` filters to a non-lifecycle field allowlist (status changes go through cancel/pause/resume); subscription status actions update in place instead of redirecting.

### Changed
- Subscription-type, billing-profile, and order forms migrated to core `<.input>`/`<.select>`/`<.textarea>` components with `assign_form/2` so inline errors render on validate.
- `SubscriptionType.billing_period_days/1` and `next_billing_date/2` gained catch-all clauses (fall back to a monthly cadence) instead of raising on an unexpected interval.
- Stripe provider moduledoc corrected to document the real `PhoenixKit.Settings`-based configuration; the provider talks to the Stripe REST API over `Req`.
- Upgraded locked dependencies; added a test-only `lazy_html` dependency for `Phoenix.LiveViewTest`.

## [0.3.2] - 2026-05-25

### Changed
- **Internationalized the billing admin UI.** Every user-visible string across the admin pages (dashboard, billing settings, payment providers, currencies, subscription types & subscriptions, billing profiles, orders, invoices, transactions) now routes through the per-module `PhoenixKitBilling.Gettext` backend, with full English, Russian, and Estonian catalogues. Print templates (invoice/receipt/credit-note/payment-confirmation) intentionally remain on `PhoenixKitWeb.Gettext` due to their legal-formatting concerns.
- Moved page-level filters, search, clear-filters, and refresh controls into the table toolbar row (`:toolbar_title` / `:toolbar_actions`) for Subscriptions, Billing Profiles, Currencies, Transactions, Invoices, and Orders, grouping related controls and freeing vertical space.
- Upgraded locked dependencies (`ecto`/`ecto_sql` 3.14, `phoenix_kit` 1.7.120, `req` 0.5.18, `etcher`, `fresco`, `ex_doc`, `hammer`). No change to declared version requirements.

### Fixed
- `SubscriptionHelpers.format_interval/2` returned hardcoded English ("Monthly", "Every 3 months", …) and is rendered on six already-localized subscription pages, so it leaked English under `ru`/`et`. It now uses `gettext`/`ngettext` with complete en/ru/et plural forms. (The catalogue drift test could not catch this because the strings were never `gettext` msgids.)

## [0.3.1] - 2026-05-18

### Fixed
- `PhoenixKitBilling.create_checkout_session/3` was unusable — every call crashed:
  - It called `Providers.create_checkout_session/2` with a hand-built options map in the invoice position, so the provider received an empty `opts` keyword list and raised `KeyError` on `success_url`. It now forwards the real `%Invoice{}` struct and passes `opts` through, with `:cancel_url` defaulting to `:success_url`. The provider already derives amount, currency, line items and metadata from the invoice.
  - On success it wrote `checkout_session_id` / `checkout_url` via `Ecto.Changeset.change/2`, but neither field exists on the `Invoice` schema, raising `ArgumentError: unknown field`. Checkout session details are now recorded under `invoice.metadata["checkout"]` (`provider_session_id`, `url`, `provider`, `created_at`); persistence is best-effort and a failed update no longer discards the live session URL returned to the caller.

## [0.3.0] - 2026-05-18

### Added
- **EveryPay payment provider** (`PhoenixKitBilling.Providers.EveryPay`) — EveryPay AS (Baltics) gateway, API v4. Supports one-off hosted-page payments, charging saved card tokens for renewals (MIT), and refunds. Registered as the `:everypay` provider and the `everypay` payment-option code.
- EveryPay callback endpoint `POST /webhooks/billing/everypay`. EveryPay v4 callbacks are unsigned, so the handler re-fetches the authoritative payment record from the API and acts only on that — a forged callback body cannot change billing state.
- EveryPay configuration panel on the Payment Providers admin page (API username/secret, processing account name, test/live mode).

## [0.2.0] - 2026-05-12

### Added
- `PhoenixKitBilling.Plugs.CacheBodyReader` — body reader for `Plug.Parsers` that stashes the raw request body on `conn.assigns.raw_body` for `/webhooks/billing/*` paths so provider signatures can be verified. Required for webhook signature verification to function (see install instructions).
- Live updates on the invoice detail page: subscribes to invoice + transaction PubSub events and refreshes when payments or refunds land.
- Line-item validation on the `Invoice` changeset (name, positive quantity, total).
- Per-subscription `unique` key on `SubscriptionRenewalWorker` so concurrent enqueues for the same subscription collapse correctly.

### Changed
- **Webhook processor:** refunds are now actually recorded via `Billing.record_refund/3` (previously just logged), with handling for `:exceeds_paid_amount`. Idempotency now uses an upsert that distinguishes new / retry / already-processed events, and stack traces are formatted with `Exception.format/3`.
- **Subscription renewal worker:** batch runs now fan out into one job per subscription instead of processing inline, so a single bad subscription cannot poison the whole daily run and the per-subscription unique key + row lock apply correctly.
- **Subscription dunning worker:** fixed off-by-one in max-attempts comparison — a subscription is now cancelled when the *next* attempt would exceed the cap, and the next retry is only scheduled when a future attempt is still allowed.
- **LiveView mount/handle_params split:** moved DB reads out of `mount/3` and into `handle_params/3` for `BillingProfileForm`, `OrderForm`, `Subscriptions`, and `InvoiceDetail` (mount runs twice — once for the dead render and once on connect — so queries belong in `handle_params`).
- **Webhook controller:** logs an explicit, actionable error when `raw_body` is missing from `conn.assigns` instead of silently failing.

### Required action for host applications
Wire the new body reader into your `Endpoint`'s `Plug.Parsers` (see `PhoenixKitBilling.Plugs.CacheBodyReader` moduledoc and the updated install task output for the exact snippet). Without it, webhook signature verification cannot run and webhook requests will be rejected.

## [0.1.5] - 2026-05-08

### Added
- Per-module Gettext backend (`PhoenixKitBilling.Gettext`) with `en`/`ru`/`et` catalogues for all admin sidebar tab labels. Requires `phoenix_kit` release that ships the `gettext_backend` Tab API ([BeamLabEU/phoenix_kit#522](https://github.com/BeamLabEU/phoenix_kit/pull/522)); on older releases tabs render raw English (graceful degradation).

## [0.1.4] - 2026-04-06

### Added
- Add `version/0` callback to display package version on modules page
- Add `module_stats/0` for admin module card (orders, invoices, currencies)
- Expand compat module with full delegation list

### Changed
- Migrate `CountryData.get_company_info` / `get_bank_details` to `Organization` module
- Move `format_company_address/1` to own module for better testability
- Updated permission metadata and icon

## [0.1.3] - 2026-03-30

### Added

- Public tax rate API: `tax_enabled?/0`, `get_tax_rate/0`, `get_tax_rate_percent/0` for cross-module use
- Compat delegates for tax rate API and `get_config/0` in `PhoenixKit.Modules.Billing`

### Fixed

- `get_tax_rate_percent/0` now respects `tax_enabled?` flag
- `get_tax_rate/0` handles non-numeric settings values without crashing
- `get_config/0` uses `tax_enabled?/0` instead of inlining the check

## [0.1.2] - 2026-03-30

### Added

- Subscription edit mode with status management (pause/resume/cancel) and plan type change
- Admin detail/form routes via `admin_routes/0` and `admin_locale_routes/0`
- `table_default` component with card/table toggle across all list pages
- Dropdown menus (`table_row_menu`) on all list pages replacing inline action buttons
- Subscription schema fields: `plan_name`, `price`, `currency`, `provider`, `provider_subscription_id`, `last_renewal_error`, `belongs_to :user`
- Backward-compatible compat modules for `PhoenixKit.Modules.Billing.*` namespace
- Shared `SubscriptionHelpers` module for `status_badge_class/1` and `format_interval/2`
- Confirmation dialogs on destructive subscription actions (pause, cancel)

### Fixed

- Webhook routes now use `phoenix_kit_api` pipeline (was `api`)
- PaymentMethod schema field mismatch: `label` → `display_name` to match DB column
- Removed `try/rescue` blocks in subscription form that were masking the schema mismatch
- Hardcoded `"EUR"` fallback in `create_subscription` now uses `billing_default_currency` setting
- Added `last_renewal_error` to subscription changeset cast list
- Cancel flash message in edit form now correctly says "will be cancelled at period end"

### Changed

- Refactored `admin_locale_routes/0` to share `build_admin_routes/1` with `admin_routes/0`
- Removed duplicate `alias Routes` declarations in subscription LiveViews

## [0.1.1] - 2026-03-29

### Changed

- Restructured to flat `lib/phoenix_kit_billing/` layout with `PhoenixKitBilling` namespace
- Added `.gitignore` for clean repository tracking

### Fixed

- Sorted alias declarations alphabetically across 33 files to satisfy Credo strict mode

## [0.1.0] - 2026-03-28

### Added

- Initial billing module with PhoenixKit.Module behaviour
- Multi-currency support with exchange rates
- Billing profiles for individuals and companies
- Order management with line items and status tracking
- Invoice generation with receipt functionality (draft → sent → paid/overdue/void)
- Transaction tracking with refunds and credit notes
- Subscription management with renewal cycles and dunning
- Subscription type definitions (pricing, intervals, trial periods)
- Payment provider architecture (Stripe, PayPal, Razorpay)
- Internal subscription control (subscriptions managed in DB, not by providers)
- Webhook processing for all supported providers
- Oban workers for subscription renewals and dunning
- PubSub events for real-time LiveView updates
- Admin LiveViews: dashboard, orders, invoices, transactions, subscriptions, billing profiles, currencies, settings
- User dashboard: My Orders, Billing Profiles
- Print views: invoice, receipt, credit note, payment confirmation
- Centralized path helpers via Paths module
- Install mix task
