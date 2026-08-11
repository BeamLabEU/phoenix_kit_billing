# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.7.0] - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved from `~> 1.7.214` to
  `~> 2.0`, so this release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself; there is no behaviour change in billing.

## [0.6.0] - 2026-08-09

PR #18 plus its post-merge review. The PR contributes a **Customer billing** tab
to the `phoenix_kit_projects` hub. The review found the tab's unlinked state
enumerating every billing profile in the installation, and four places where it
reimplemented shared billing UI or skipped conventions the sibling CRM tab
already follows. Full findings in
`dev_docs/pull_requests/2026/18-project-billing-tab/CLAUDE_REVIEW.md`.

### Added
- **`phoenix_kit_project_extensions/0` — the Customer billing tab for the projects hub** (PR #18). A duck-typed catalog entry (plain maps; no dependency on `phoenix_kit_projects`, no FK) that links a project to a billing profile by UUID and renders that customer's recent invoices inside the project page via `PhoenixKitBilling.Web.ProjectBillingLive`. Honestly labeled: the tab is the linked **customer's** money — everything on their profile, across everything they buy — not a per-project P&L. `rate_cents_per_hour` lives on the same extension so the projects-side ledger→invoice bridge and this tab share one money-settings home. `default_enabled: false`.
- **`:limit` filter for the invoice list functions.** `list_invoices/1` and `list_user_invoices/2` now accept `%{limit: n}`, so rollup panels can ask for the most recent few instead of loading a customer's entire invoice history and slicing it in memory.

### Fixed
- **The unlinked Customer billing tab disclosed every billing profile in the installation.** With no profile linked, the tab called `list_billing_profiles/1` with no options — which applies no user, type, search or pagination filter — and rendered every row's display name *and* UUID. Any project member opening the tab saw the identity of every customer of the whole host app, including people with no relationship to that project, and a host with thousands of profiles rendered all of them into the page on every mount. The empty state now links out to Billing › Profiles, matching the sibling CRM tab.
- **Voided and draft invoices rendered the wrong color in the tab.** It defined its own status→badge clauses instead of using `Web.Components.InvoiceStatusBadge`, and two of the five statuses disagreed with the shared component: `void` came out neutral-gray instead of red, and `draft` came out warning-yellow instead of gray. Now uses the shared component, so the two lists cannot drift again.
- **Money in the tab bypassed `Web.Components.CurrencyDisplay`**, rendering `1234.50 EUR` where the rest of billing renders `€1,234.50` — no symbol, no thousand separators, and a hardcoded 2-decimal round that is wrong for the zero-decimal currencies the shared component already handles (JPY, HUF).
- **The tab ignored the hub's locale and used no gettext.** The projects hub passes `"locale"` in the embed session; the tab dropped it and hardcoded English, so the pane rendered untranslated inside otherwise-translated ru/et project pages. All strings are now gettext-backed with `en`/`ru`/`et` translations; the catalogues are back to zero untranslated and zero fuzzy entries.

### Changed
- **The tab's reads moved behind a `connected?/1` guard.** They ran in `mount/3`, which executes twice on a full page load, so every query was paid for twice and the first result discarded. The hub requires contributed tab LVs to be mountable off-router with no `handle_params/3` (it renders them via `live_render`), which rules out the usual `handle_params` split — a new regression test asserts the LV does not export `handle_params/3`, since that failure is otherwise only visible from the projects side.
- The invoice table now fetches one row over its display cap and says "Showing the 15 most recent invoices." when there are more, instead of silently truncating.

## [0.5.3] - 2026-08-06

PR #17 plus its post-merge review. The PR fixed a callback whose absence is
completely silent; the review found the same callback still missing on the
module's other public face, and a drift test structurally unable to catch either.
Full findings in `dev_docs/pull_requests/2026/17-css-sources-callback/CLAUDE_REVIEW.md`.

### Fixed
- **Tailwind purged every class used only in billing's templates from host builds.** This module never implemented `css_sources/0`, so core's `:phoenix_kit_css_sources` compiler — which guards on `function_exported?/3` and emits nothing for a module that doesn't export it — wrote no `@source` line for the package. Nothing errored; the admin billing pages simply rendered without their responsive and variant utilities. Billing was the only PhoenixKit module missing the callback (PR #17).
- **The `PhoenixKit.Modules.Billing` compat shim still had the bug.** The shim re-exports the module surface under the pre-migration namespace, and a host can register it: `ModuleDiscovery` merges beam-scanned modules with `config :phoenix_kit, modules: [...]` — the very fallback core's zero-sources error message recommends. `css_sources/0` was not delegated, so hosts on that path kept the purged bundle. `notification_types/0` was missing for the same reason, which silently dropped billing's whole notification tree (`billing`, `invoices`, `your_billing`) from the registry.

### Changed
- The compat drift test now guards **both** directions. It previously asserted only that nothing the shim delegates has vanished from the target, so a callback *added* to `PhoenixKitBilling` and not re-exported — exactly the two above — could never be flagged. Closes the "no compat-module drift tests" item deferred in AGENTS.md.
- `css_sources/0`'s regression test now also asserts against `Application.get_application/1` rather than only a repeated literal, so a package rename fails the test instead of quietly emitting an `@source` for a directory that isn't there.
- `notification_types/0` carries `@impl PhoenixKit.Module`; it is a declared optional callback, not the duck-typed hook its doc described.
- AGENTS.md's "Tailwind CSS Scanning" section asserted this module implemented `css_sources/0` from the initial scaffolding commit onward, while the code never did — the doc confirmed the callback to anyone who checked it instead of exposing the gap. Rewritten with the real mechanism (a Mix compiler regenerating `assets/css/_phoenix_kit_sources.css`, not the installer writing `app.css`), an explicit note that the callback fails open, and a warning not to copy core's `@source_root` path-dep example here — this module's callback lives one directory shallower, so `Path.join(__DIR__, "../..")` would resolve to `deps/` and emit an `@source` over the entire dependency tree.

## [0.5.2] - 2026-08-05

Post-merge review of PR #15 (permissions, notifications, provider payments) and PR #16 (live subscriptions search). PR #15 fixed `record_payment/3` so provider-driven payments finally insert — which meant both of its production callers executed their success paths for the first time, and neither survived it. Full findings in `dev_docs/pull_requests/2026/15-permissions-notifications-payment-fixes/CLAUDE_REVIEW.md` and `.../16-subscriptions-live-search/CLAUDE_REVIEW.md`.

### Fixed
- **Subscription renewals could charge a customer up to three times.** `SubscriptionRenewalWorker` passes the provider's `%ChargeResult{}` struct as `provider_data`, and Ecto lets a struct through both `cast` and `dump` on a `:map` column — the failure only surfaces in the JSON encoder, as a **raise** from inside the repo transaction, i.e. *after* the card has been charged. The exception escaped `attempt_renewal/2`'s `with` (an `else` clause does not match exceptions), so the Oban job crashed instead of moving the subscription to `past_due`, and each retry created another invoice and charged the card again. `provider_data` is now sanitized to a plain, JSON-safe map at the context boundary, where providers' result structs arrive.
- **Every successful provider webhook payment raised `KeyError`.** `WebhookProcessor` read `.status` off `record_payment/3`'s return value, which is a `%Transaction{}` — a schema with no `:status` field. The payment committed, the webhook then 500'd, no receipt was generated, and the provider retried a charge that had already been recorded. Unreachable until provider payments started inserting at all.
- **The webhook status gate and `Invoice.payable?/1` disagreed.** `validate_invoice_status/1` admitted `"draft"`, which `record_payment/3` now rejects as `:not_payable`, so a draft invoice passed the processor's gate only to have its payment dropped downstream. It now delegates to `Invoice.payable?/1` so the two cannot drift.
- **`mark_invoice_paid/2` could commit a paid status without its ledger row.** A failed settlement insert was discarded with `_ =` rather than rolling the transaction back — the exact inconsistency that transaction exists to close. It now also takes the same `FOR UPDATE` row lock `record_payment/3` relies on, without which a concurrent mark-paid and payment could together record more than the invoice bills.
- **Every customer notification linked to a route that does not exist.** `/dashboard/invoices/<uuid>` is registered nowhere; `user_dashboard_tabs/0` exposes `orders` and `billing-profiles`. Customer invoice and payment notices now link via `Paths.user_orders/0`.
- **`billing.payment_failed` was a registered notification nothing could emit.** Notification sends stopped at the admin LiveView, so the provider paths recorded payments and failures silently. `payment_received/2` and `payment_failed/2` are now emitted from the webhook processor and the renewal worker.
- **A partial payment was announced as the invoice total** — `payment_received` formatted `invoice.total`, so 50-of-500 read as *"Payment received — 500.00 EUR"*. It now reports the amount actually recorded.
- **A decline reason could be truncated mid-codepoint.** `binary_part/3` cuts at a byte offset; a localized provider message split that way is invalid UTF-8 and is rejected by both Postgres and the JSON encoder, so the notification reporting a failed payment failed itself.
- **Back-button behaviour on the orders, invoices and transactions lists.** All three have debounced live search but pushed a history entry per typing pause, so Back walked the query backwards a few characters at a time. They now use the `replace: true` that PR #16 applied to subscriptions.

### Changed
- `Web.Authz`'s moduledoc described the e-commerce module (`"shop"` key, "carts carry customer contact details"); it now describes billing.
- `snapshot_refreshable?/1`'s doc claimed an in-place billing-profile edit refreshes a draft order's snapshot. It does not — only a profile *switch* is reconsidered, at any status or policy. The doc now states the actual scope.
- `mix.lock` pruned of eight unused entries (`igniter`, `sourceror`, `spitfire` and friends) left behind by the dependency refresh in `19525d0`, which had `mix precommit` failing on `deps.unlock --check-unused`.

### Added
- Regression coverage for the two defects above that a DB-backed test could reach: a provider result **struct** recorded as `provider_data`, and mark-paid keeping status and ledger row in one transaction.
- `test/phoenix_kit_billing/notification_contracts_test.exs` — DB-free contract tests: every registered notification action has a producer, every customer link resolves to a tab `user_dashboard_tabs/0` registers, and decline reasons truncate on a character boundary.
- `Paths.user_orders/0` and `Paths.user_billing_profiles/0` for the customer-facing routes this module registers.

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
