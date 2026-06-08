# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## Project Overview

PhoenixKit Billing — an Elixir module for payments, subscriptions, invoices, orders, billing profiles, and multi-currency support, built as a pluggable module for the PhoenixKit framework. Supports multiple payment providers (Stripe, PayPal, Razorpay) with internal subscription control. Provides admin LiveViews for managing orders, invoices, transactions, subscriptions, billing profiles, currencies, and provider settings.

## Commands

```bash
mix deps.get                # Install dependencies
mix test                    # Run all tests
mix test test/file_test.exs # Run single test file
mix test test/file_test.exs:42  # Run specific test by line
mix format                  # Format code
mix credo --strict          # Lint / code quality (strict mode)
mix dialyzer                # Static type checking
mix docs                    # Generate documentation
mix precommit               # compile + format + credo --strict + dialyzer
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
```

## Local cross-repo development

`phoenix_kit` (and any sibling `phoenix_kit_*` dep) resolves from Hex by
default. To build or test this module against a **local checkout** of a
dependency — e.g. an unpublished core change — export `<APP>_PATH` and Mix
swaps the Hex pin for a `path:` + `override: true` dep at resolve time:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test     # this module against local core
```

The variable name is the dep's app name upper-cased with `_PATH` appended
(`:phoenix_kit` -> `PHOENIX_KIT_PATH`, `:phoenix_kit_ai` ->
`PHOENIX_KIT_AI_PATH`). Set several at once to override multiple deps. **Unset = the
published pin**, so `mix hex.publish` and CI resolve exactly as before.
Implemented via `pk_dep/3` in `mix.exs` — never hand-edit a `phoenix_kit*`
dep into a `path:` tuple (a committed path dep ships a broken package); set
the env var instead.

## Architecture

This is a **library** (not a standalone Phoenix app) that provides billing as a PhoenixKit plugin module.

### Core Schemas (all use UUIDv7 primary keys)

- **BillingProfile** — user billing information (individuals & companies), address, tax ID, IBAN
- **Order** — order with line items, status tracking, billing snapshot
- **Invoice** — generated from orders, status workflow (draft → sent → paid/overdue/void), receipt generation
- **Transaction** — payment records linked to invoices, supports refunds and credit notes
- **Subscription** — internal subscription management with renewal cycles and dunning
- **SubscriptionType** — subscription plan definitions (pricing, intervals, trial periods)
- **PaymentMethod** — saved payment methods from providers
- **PaymentOption** — available payment options for checkout
- **Currency** — multi-currency support with exchange rates
- **WebhookEvent** — provider webhook event log

### Provider Architecture

PhoenixKit uses **Internal Subscription Control** — subscriptions are managed in our database, not by providers. Providers only handle:
- One-time payments (hosted checkout sessions)
- Saving payment methods for recurring billing
- Charging saved payment methods
- Processing refunds

The `Provider` behaviour defines 9 callbacks. Three implementations exist:
- **Stripe** — primary provider via `stripity_stripe`
- **PayPal** — via REST API
- **Razorpay** — via REST API

### Contexts

- **Billing** (main module) — system config, order CRUD, invoice CRUD, transaction management, subscription lifecycle, billing profile management, currency operations
- **Events** — PubSub broadcasts for real-time LiveView updates
- **Providers** — provider registry, availability checks, routing to correct provider
- **WebhookProcessor** — normalizes and processes provider webhooks into transactions/status updates

### Workers (Oban)

- **SubscriptionRenewalWorker** — processes subscription renewals by charging saved payment methods
- **SubscriptionDunningWorker** — handles failed payment retries and grace period management

### PubSub Topics

- `phoenix_kit:billing:orders` — order events (created, updated, confirmed, paid, cancelled)
- `phoenix_kit:billing:invoices` — invoice events (created, sent, paid, voided)
- `phoenix_kit:billing:profiles` — billing profile events (created, updated, deleted)
- `phoenix_kit:billing:transactions` — transaction events (created, refunded)
- `phoenix_kit:billing:credit_notes` — credit note events (sent, applied)
- `phoenix_kit:billing:subscriptions` — subscription events (created, cancelled, renewed, type/status changed)

All topics support per-user subscriptions via `:user:<user_uuid>` suffix.

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config)
3. `admin_tabs/0` callback registers admin pages; PhoenixKit generates routes at compile time
4. `settings_tabs/0` registers settings under admin settings
5. `user_dashboard_tabs/0` registers "My Orders" and "Billing Profiles" in user dashboard
6. `route_module/0` provides webhook routes via `Web.Routes`
7. Settings are persisted via `PhoenixKit.Settings` API (DB-backed in parent app)
8. Permissions are declared via `permission_metadata/0` and checked via `Scope.has_module_access?/2`

### Web Layer

- **Admin** (13 LiveViews): Index (dashboard), Orders, OrderForm, OrderDetail, Invoices, InvoiceDetail, Transactions, Subscriptions, SubscriptionDetail, SubscriptionForm, SubscriptionTypes, SubscriptionTypeForm, BillingProfiles, BillingProfileForm, Currencies, Settings, ProviderSettings
- **User Dashboard** (2 LiveViews): UserBillingProfiles, UserBillingProfileForm
- **Print Views**: InvoicePrint, ReceiptPrint, CreditNotePrint, PaymentConfirmationPrint
- **Components**: CurrencyDisplay, InvoiceStatusBadge, OrderStatusBadge, TransactionTypeBadge
- **Public** (1 Controller): `WebhookController` (Stripe/PayPal/Razorpay webhooks)
- **Routes**: `route_module/0` provides webhook routes; admin routes auto-generated from `admin_tabs/0`
- **Paths**: Centralized path helpers in `Paths` module — always use these instead of hardcoding URLs

### Settings Keys

All stored via PhoenixKit Settings with module `"billing"`:

- `billing_enabled` — enable/disable the entire billing system
- `billing_default_currency` — default currency code (default: "EUR")
- `billing_tax_enabled` — enable tax calculations
- `billing_company_name`, `billing_company_address`, etc. — company info for invoices

### Invoice Status Workflow

```
draft → sent → paid
            ↘
           overdue → paid
            ↘
            void
```

### File Layout

```
lib/
├── phoenix_kit_billing.ex                    # Main module (PhoenixKit.Module behaviour + context)
└── phoenix_kit_billing/
    ├── mix_tasks/
    │   └── phoenix_kit_billing.install.ex    # Install mix task
    ├── application_integration.ex    # Provider registration on startup
    ├── events.ex                     # PubSub event broadcasts
    ├── paths.ex                      # Centralized URL path helpers
    ├── supervisor.ex                 # OTP Supervisor
    ├── providers/
    │   ├── provider.ex               # Provider behaviour (9 callbacks)
    │   ├── providers.ex              # Provider registry and routing
    │   ├── stripe.ex                 # Stripe implementation
    │   ├── paypal.ex                 # PayPal implementation
    │   ├── razorpay.ex               # Razorpay implementation
    │   └── types/                    # Shared provider types
    │       ├── charge_result.ex
    │       ├── checkout_session.ex
    │       ├── payment_method_info.ex
    │       ├── provider_info.ex
    │       ├── refund_result.ex
    │       ├── setup_session.ex
    │       └── webhook_event_data.ex
    ├── schemas/
    │   ├── billing_profile.ex        # User billing information
    │   ├── currency.ex               # Currency definitions
    │   ├── invoice.ex                # Invoice with receipt
    │   ├── order.ex                  # Order with line items
    │   ├── payment_method.ex         # Saved payment methods
    │   ├── payment_option.ex         # Available payment options
    │   ├── subscription.ex           # Subscription records
    │   ├── subscription_type.ex      # Subscription plan definitions
    │   ├── transaction.ex            # Payment/refund transactions
    │   └── webhook_event.ex          # Provider webhook log
    ├── utils/
    │   ├── iban_data.ex              # IBAN validation data
    │   └── webhook_processor.ex      # Webhook normalization and processing
    ├── workers/
    │   ├── subscription_renewal_worker.ex   # Oban: subscription renewals
    │   └── subscription_dunning_worker.ex   # Oban: failed payment retries
    └── web/
        ├── routes.ex                 # Public route generation (webhooks)
        ├── webhook_controller.ex     # Stripe/PayPal/Razorpay webhook handler
        ├── index.ex                  # Dashboard LiveView
        ├── orders.ex                 # Orders list LiveView
        ├── order_form.ex             # Order create/edit LiveView
        ├── order_detail.ex           # Order detail LiveView
        ├── invoices.ex               # Invoices list LiveView
        ├── invoice_detail.ex         # Invoice detail LiveView
        ├── invoice_detail/           # Invoice detail submodules
        │   ├── actions.ex
        │   ├── helpers.ex
        │   └── timeline_event.ex
        ├── invoice_print.ex          # Invoice print view
        ├── receipt_print.ex          # Receipt print view
        ├── credit_note_print.ex      # Credit note print view
        ├── payment_confirmation_print.ex  # Payment confirmation print
        ├── transactions.ex           # Transactions list LiveView
        ├── subscriptions.ex          # Subscriptions list LiveView
        ├── subscription_detail.ex    # Subscription detail LiveView
        ├── subscription_form.ex      # Subscription create LiveView
        ├── subscription_types.ex     # Subscription types list LiveView
        ├── subscription_type_form.ex # Subscription type create/edit LiveView
        ├── billing_profiles.ex       # Admin billing profiles LiveView
        ├── billing_profile_form.ex   # Admin billing profile form LiveView
        ├── user_billing_profiles.ex  # User dashboard billing profiles
        ├── user_billing_profile_form.ex  # User dashboard profile form
        ├── currencies.ex             # Currencies LiveView
        ├── settings.ex               # Settings LiveView
        ├── provider_settings.ex      # Provider settings LiveView
        └── components/
            ├── currency_display.ex
            ├── invoice_status_badge.ex
            ├── order_status_badge.ex
            └── transaction_type_badge.ex
```

## Critical Conventions

- **Module key** must be consistent across all callbacks: `"billing"`
- **UUIDv7 primary keys** — all schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true}` and `uuid_generate_v7()` in migrations (never `gen_random_uuid()`)
- **Oban workers** — subscription renewals and dunning use Oban workers; never spawn bare Tasks for async billing operations
- **Centralized paths via `Paths` module** — never hardcode URLs or route paths in LiveViews or controllers; use `Paths` helpers or `PhoenixKit.Utils.Routes.path/1` for cross-module links
- **Admin routes from `admin_tabs/0`** — all admin navigation is auto-generated by PhoenixKit Dashboard from the tabs returned by `admin_tabs/0`; do not manually add admin routes elsewhere
- **Public routes from `route_module/0`** — the single public entry point is `Web.Routes`; `route_module/0` returns this module so PhoenixKit registers webhook routes automatically
- **LiveViews use `PhoenixKitWeb` `:live_view`** — this module uses `use PhoenixKitWeb, :live_view` for correct admin layout integration (sidebar/header)
- **Navigation paths**: always use `PhoenixKit.Utils.Routes.path/1`, never relative paths
- **`enabled?/0`**: must rescue errors and return `false` as fallback (DB may not be available)
- **Provider registration is automatic** — `ApplicationIntegration.register()` is called during `Supervisor.init/1`; the host app does not need to configure providers manually
- **Settings via PhoenixKit Settings** — all config is stored in the PhoenixKit settings system, not in application env; use `Billing.get_config/0` and related functions
- **LiveView assigns** available in admin pages: `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`
- **Tab IDs**: prefixed with `:admin_billing` (main tabs) and `:admin_settings_billing` (settings tab)
- **URL paths**: `/admin/billing` (dashboard), `/admin/settings/billing` (settings), use hyphens not underscores
- **Internal subscription control** — subscriptions are managed in our database; providers only handle payment collection
- **Decimal for money** — all monetary amounts use `Decimal` type; never use floats for currency

## Tailwind CSS Scanning

This module implements `css_sources/0` returning `[:phoenix_kit_billing]` so PhoenixKit's installer adds the correct `@source` directive to the parent's `app.css`. Without this, Tailwind purges CSS classes unique to this module's templates.

## Versioning & Releases

### Tagging & GitHub releases

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.1
git push origin 0.1.1
```

GitHub releases are created with `gh release create` using the tag as the release name. The title format is `<version> - <date>`, and the body comes from the corresponding `CHANGELOG.md` section:

```bash
gh release create 0.1.1 \
  --title "0.1.1 - 2026-03-28" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in `mix.exs`
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag x.y.z && git push origin x.y.z`
7. Create GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## Testing

### Harness

The module ships a full test harness (added 2026-06-04):

- **`PhoenixKitBilling.DataCase`** (`test/support/data_case.ex`) — DB-backed
  case template with the Ecto SQL sandbox; use for schema, changeset, and
  context tests.
- **`PhoenixKitBilling.LiveCase`** (`test/support/live_case.ex`) — LiveView
  case template wired to the test `Endpoint` + `Router`; use for admin LV
  smoke / interaction tests.
- **Test `Endpoint` + `Router`** under `test/support/` host the module's
  LiveViews in isolation (no parent app required).
- Schema setup runs core's versioned migrations via
  `PhoenixKit.Migration.ensure_current/2` in `test_helper.exs` — no
  module-owned DDL.
- Test-only deps: `lazy_html` (HTML assertions). A `.dialyzer_ignore.exs`
  filters known third-party warnings.

### Running tests

```bash
createdb phoenix_kit_billing_test   # one-time: create the test database
mix test                            # all tests (177 tests; 3 skipped — see below)
mix test test/phoenix_kit_billing/schemas        # a directory
mix test test/phoenix_kit_billing_test.exs:42    # a single test
```

The 3 skipped tests are `@tag :skip` pending a **core** fix: on a fresh
`PhoenixKit.Migration.ensure_current/2` build, `phoenix_kit_subscriptions`
lacks the `subscription_type_uuid` column (core V65 renames a column that
V33 never created), so `Subscription` inserts and the Subscriptions LV
raise `undefined_column`. See the "Deferred from the 2026-06-04 quality
sweep" section below.

## Host-Integration Callouts

⚠️ **Webhook signature verification requires the host to wire
`PhoenixKitBilling.Plugs.CacheBodyReader` into `Plug.Parsers`.** Provider
webhooks (Stripe/PayPal/Razorpay) verify the signature against the **raw**
request body, so the host endpoint must pass
`body_reader: {PhoenixKitBilling.Plugs.CacheBodyReader, :read_body, []}`
to `Plug.Parsers`. This is wired automatically by
`mix phoenix_kit_billing.install`. **Without it, webhooks return `400`
with `:no_raw_body` before any processing happens** — the raw body has
already been consumed by the default parser and the signature check can't
run.

To exercise the Stripe webhook path on **localhost** (configure test keys via
`/admin/settings/billing/providers`, forward with the Stripe CLI
`stripe listen --api-key … --forward-to …/webhooks/billing/stripe`, set the
printed `whsec_…` as the Webhook Secret, then `stripe trigger`), see the
**"Testing Stripe locally"** section in `README.md`.

## Deferred from the 2026-06-04 quality sweep

The Phase 1 / Phase 2 sweep on 2026-06-04 fixed the PR-review backlog,
added the test harness above, and then completed most of the items that
were initially deferred.

**Completed in the sweep:**
- **(a) Module-wide activity logging** — `PhoenixKitBilling.Activity`
  LV-layer wrapper logged on every admin mutation; PII-safe; covered by
  `test/phoenix_kit_billing/activity_logging_test.exs`.
- **(b) `Errors` module** — `PhoenixKitBilling.Errors.message/1` maps the
  module's atom errors to gettext-backed strings;
  `test/phoenix_kit_billing/errors_test.exs` pins each.
- **(d, partial) Subscription-admin items** — `update_subscription/2` now
  filters to a non-lifecycle field allowlist; `extend_subscription`
  derives the period from the subscription type (was hardcoded 30 days);
  status actions update in place instead of redirecting. (Row-click was
  already consistent across the list LVs.)

**Still remaining (genuinely out of scope for now):**
- **(c) Component migration tail.** The subscription-type, billing-profile,
  and order forms were migrated to core `<.input>/<.select>/<.textarea>`.
  Still raw by design/risk: the order form's customer/billing-profile
  dynamic selects and per-row line-item inputs (custom `phx-` handling,
  no changeset backing), checkbox/radio groups with bespoke daisyUI
  layouts, and filter/action selects on the list pages.
- **(d, remaining)** edit-save ignoring payment-method changes; no
  compat-module drift tests. See
  `dev_docs/pull_requests/2026/3-fix-billing-ui/FOLLOW_UP.md`.
- **(e) ⚠️ CORE bug to surface to Max — `subscription_type_uuid`
  missing column.** On a fresh `PhoenixKit.Migration.ensure_current/2`
  build, `phoenix_kit_subscriptions` is missing the
  `subscription_type_uuid` column: **core migration V65 renames a column
  that V33 never created.** Subscription inserts and the Subscriptions
  LiveView both raise `undefined_column`. Three tests are `@tag :skip`
  pending the core fix — they will pass once core ships the corrected
  migration. This is a **core `phoenix_kit` defect**, not a billing-module
  bug; flagged here for Max to schedule the core fix + pin bump.

## Pull Requests

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`).

### Review file format

```markdown
# Code Review: PR #<number> — <title>

**Reviewed:** <date>
**Reviewer:** Claude (claude-opus-4-6)
**PR:** <GitHub URL>
**Author:** <name> (<GitHub login>)
**Head SHA:** <commit SHA>
**Status:** <Merged | Open>

## Summary
<What the PR does>

## Issues Found
### 1. [<SEVERITY>] <title> — <FIXED if resolved>
**File:** <path> lines <range>
**Confidence:** <score>/100

## What Was Done Well
<Positive observations>

## Verdict
<Approved | Approved with fixes | Needs Work> — <reasoning>
```

Severity levels: `BUG - CRITICAL`, `BUG - HIGH`, `BUG - MEDIUM`, `NITPICK`, `OBSERVATION`

When issues are fixed in follow-up commits, append `— FIXED` to the issue title and update the Verdict section.

Additional files per PR directory:
- `README.md` — PR summary (what, why, files changed)
- `FOLLOW_UP.md` — post-merge issues, discovered bugs
- `CONTEXT.md` — alternatives considered, trade-offs

## External Dependencies

- **PhoenixKit** (`~> 1.7`) — Module behaviour, Settings API, shared components, RepoHelper, Utils (Date, UUID, Routes), Users.Auth.User, Users.Roles, PubSub.Manager
- **Phoenix LiveView** (`~> 1.1`) — Admin LiveViews
- **Phoenix** (`~> 1.7`) — Web framework (controllers, routing)
- **Ecto SQL** (`~> 3.12`) — Database queries and schemas
- **Oban** (`~> 2.20`) — Background job processing (subscription renewals, dunning)
- **UUIDv7** (`~> 1.0`) — UUIDv7 primary key generation
- **Stripity Stripe** (`~> 3.2`) — Stripe payment provider integration
- **Req** (`~> 0.5`) — HTTP client for PayPal/Razorpay APIs
- **Jason** (`~> 1.4`) — JSON encoding/decoding
- **ex_doc** (`~> 0.39`, dev only) — Documentation generation
- **credo** (`~> 1.7`, dev/test) — Static analysis
- **dialyxir** (`~> 1.4`, dev/test) — Type checking
