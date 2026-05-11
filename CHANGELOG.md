# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
