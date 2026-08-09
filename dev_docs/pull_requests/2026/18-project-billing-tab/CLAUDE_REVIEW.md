# Code Review: PR #18 — Contribute the Customer billing tab to the projects hub

**Reviewed:** 2026-08-09
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/18
**Author:** Max Don (mdon)
**Head SHA:** 6839672
**Merge commit:** 45144c3
**Status:** Merged

## Summary

Adds `PhoenixKitBilling.phoenix_kit_project_extensions/0` — the duck-typed
catalog entry the `phoenix_kit_projects` hub discovers — plus the tab LiveView
it points at (`PhoenixKitBilling.Web.ProjectBillingLive`) and a contract test.

The extension links a project to a **billing profile** by UUID (config-based,
no FK, no dependency on the projects package) and renders that customer's
recent invoices inside the project hub. `rate_cents_per_hour` is declared on
the same extension so the projects-side ledger→invoice bridge and this tab
share one money-settings home. Labeling is deliberately "Customer billing", not
a per-project P&L — that honesty is correct and is preserved by every fix below.

Verified the contract against the real consumer
(`/workspace/phoenix_kit_projects/lib/phoenix_kit_projects/extensions/extension.ex`
and the `live_render` call site in `project_show_live.ex`) rather than against
the PR description.

## Issues Found

### 1. [BUG - HIGH] Unlinked state dumped every billing profile in the installation — FIXED

**File:** `lib/phoenix_kit_billing/web/project_billing_live.ex` lines 36–38, 128–140 (as merged)
**Confidence:** 95/100

When no profile was linked, `mount/3` called:

```elixir
candidates = if profile, do: [], else: safe(fn -> PhoenixKitBilling.list_billing_profiles() end) || []
```

`list_billing_profiles/1` with no opts applies **no** `user_uuid`, type, search,
or pagination filter — it returns every billing profile row in the host
installation. The template then rendered each one's display name **and UUID**.

Two problems, one severity:

- **Cross-customer disclosure.** Any project member who opens an unlinked
  Customer billing tab sees the name/company name of every customer of the
  entire host app — people with no relationship to that project. The hub's
  trust model authorizes *project* access; it cannot authorize this, because
  the data isn't project-scoped at all. This module's own `Web.Authz` moduledoc
  states the invariant being broken here: pages whose **content** is privileged
  check on mount, because customer identity data is privileged.
- **Unbounded render.** No limit and no pagination — a host with 10k profiles
  renders 10k rows into the project page on every mount.

The CRM tab this was modeled on
(`PhoenixKitCRM.Web.ProjectClientLive`) does **not** do this; its empty state
just links to CRM › Companies. The dump was a deviation from the pattern, not
the pattern.

**Fix:** dropped the `candidates` query and assign entirely; the empty state now
links to `Paths.billing_profiles()`, mirroring CRM. This also removes one of the
two mount queries.

### 2. [BUG - MEDIUM] Whole invoice history loaded per mount, then sliced in memory — FIXED

**File:** `lib/phoenix_kit_billing/web/project_billing_live.ex` lines 30–35 (as merged)
**Confidence:** 97/100

```elixir
(safe(fn -> PhoenixKitBilling.list_user_invoices(profile.user_uuid) end) || [])
|> Enum.take(@invoices_limit)
```

`list_user_invoices/2` has no implicit bound — it selects and decodes *every*
invoice the customer has ever had (each carrying `line_items`, `billing_details`
and `bank_details` maps) so that 15 can be kept. For a long-standing customer
that is thousands of rows of JSON per tab open, doubled by issue #3.

**Fix:** added a `{:limit, n}` clause to the shared `apply_invoice_filters/2`
(so `list_invoices/1` and `list_user_invoices/2` both gain it) and the tab now
asks for `@invoices_limit + 1` rows — one over the cap, which tells it whether
to show "Showing the 15 most recent invoices." without a second `COUNT` query.
Covered by a new test in `integration/context_test.exs`.

### 3. [BUG - MEDIUM] Database queries in `mount/3` — FIXED

**File:** `lib/phoenix_kit_billing/web/project_billing_live.ex` lines 27–45 (as merged)
**Confidence:** 90/100

Both reads ran unconditionally in `mount/3`, which runs twice on a full page
load with the tab active (static render, then the WebSocket connect) — every
query paid for twice, the first result thrown away.

The usual remedy (move the reads to `handle_params/3`) is **not available
here**: the hub's contract explicitly requires contributed tab LVs to be
mountable off-router with no `handle_params/3`, because it renders them via
`live_render`. Exporting it would make LiveView demand a router match and the
embed would raise.

**Fix:** the reads moved into a `load/2` behind a `connected?/1` guard, with
mount assigning the empty defaults. Also added a regression test asserting the
LV does not export `handle_params/3` — that failure is otherwise only visible
from the projects side, which does not depend on this package.

### 4. [BUG - MEDIUM] Reimplemented status colors drifted from `InvoiceStatusBadge` — FIXED

**File:** `lib/phoenix_kit_billing/web/project_billing_live.ex` lines 132–135 (as merged)
**Confidence:** 99/100

The tab defined its own `status_class/1` rather than using the module's shared
`Web.Components.InvoiceStatusBadge`, and two of the five statuses in
`Invoice`'s `@valid_statuses` came out a different color than everywhere else
in the app:

| status | shared component | PR's local clause | |
|---|---|---|---|
| `draft` | `badge-ghost` | `badge-warning` (fallback) | ✗ |
| `sent` | `badge-info` | `badge-info` | ✓ |
| `paid` | `badge-success` | `badge-success` | ✓ |
| `void` | `badge-error` | `badge-ghost` | ✗ |
| `overdue` | `badge-warning` | `badge-warning` (fallback) | ✓ |

A voided invoice rendering as neutral-gray instead of red is the one that
actually misleads. The shared component also capitalizes the label; the tab
printed the raw lowercase status.

**Fix:** use `<.invoice_status_badge status={invoice.status} />`. The whole
local clause set is gone, so it cannot drift again.

### 5. [BUG - MEDIUM] Money formatting bypassed `CurrencyDisplay` — FIXED

**File:** `lib/phoenix_kit_billing/web/project_billing_live.ex` line 138 (as merged)
**Confidence:** 95/100

```elixir
defp money(total, currency), do: "#{Decimal.round(total, 2)} #{currency}"
```

Renders `1234.50 EUR` where every other billing surface renders `€1,234.50`:
no symbol, no thousand separators, and `Decimal.round(_, 2)` is wrong for the
zero-decimal currencies `CurrencyDisplay` already handles (JPY, HUF) — ¥1500
would print as `1500.00 JPY`.

**Fix:** use `<.currency_compact amount={...} currency={...} />`, keeping an
explicit `—` for a nil `total` (the component would render `€0.00`, which
misstates an unknown total as a zero one).

### 6. [BUG - MEDIUM] Locale ignored; all strings hardcoded English — FIXED

**File:** `lib/phoenix_kit_billing/web/project_billing_live.ex` (whole render) (as merged)
**Confidence:** 92/100

The hub passes `"locale"` in the embed session and the CRM tab honors it with a
`maybe_put_locale/1`. This tab dropped it and used no gettext at all, so the
pane rendered English inside an otherwise-translated ru/et project page — in a
module whose entire web layer is gettext-backed and whose `ru`/`et` catalogues
were at 100% coverage before this PR.

**Fix:** added `use Gettext, backend: PhoenixKitBilling.Gettext` and
`maybe_put_locale/1` (matching CRM), wrapped every user-facing string, added the
9 new msgids to `priv/gettext/default.pot` following that file's documented
manual-maintenance workflow, ran `mix gettext.merge priv/gettext`, and wrote
real `en`/`ru`/`et` translations. All three catalogues are back to zero
untranslated and zero fuzzy entries.

### 7. [OBSERVATION] The tab shows customer invoices to any project viewer — by design, flagged

**File:** `lib/phoenix_kit_billing/web/project_billing_live.ex`
**Confidence:** 88/100

Worth stating explicitly since it is not obvious from either side: this LV
performs **no** permission check, and that is the hub's documented contract —
the tab does not hold a scope, the host resolves `can_write` and admits the
viewer before rendering the pane. The consequence is that *project-level*
access grants sight of the *linked customer's* full invoice list (numbers,
statuses, totals, dates), which is a broader audience than the `billing`
admin-route gate allows.

That looks intentional — it is what "the customer's invoices in context" means,
the extension is `default_enabled: false`, and linking requires an admin to
paste a UUID in the Modules panel. Not changed. Recorded so the decision is on
the record rather than an accident, and so a future reviewer doesn't have to
re-derive it. If it should be narrower, the hook is the extension's
`permission_actions` plus a host-side check — not a check inside this LV, which
has no scope to check against.

### 8. [OBSERVATION] Date rendering is UTC and format-fixed

**File:** `lib/phoenix_kit_billing/web/project_billing_live.ex` (invoice date cell)
**Confidence:** 80/100

`Calendar.strftime(invoice.inserted_at, "%b %-d, %Y")` ignores the host's
configured date format (`PhoenixKit.Utils.Date.format_date_with_user_format/1`)
and the viewer's timezone.

Not changed: this module's web layer formats no other dates, so there is no
in-repo convention being violated, and the settings-aware helper would add a
settings read per row for a 15-row panel. Noted rather than fixed — if billing
adopts a date convention later, this cell should follow it.

### 9. [NITPICK] Extension entry splits the `@impl` run

**File:** `lib/phoenix_kit_billing.ex` lines 116–148

`phoenix_kit_project_extensions/0` was inserted between `module_key/0` and
`module_name/0`, breaking up the contiguous block of `@impl PhoenixKit.Module`
callbacks with a non-callback function. Cosmetic; left alone to keep the diff
reviewable against the PR.

## What Was Done Well

- **The decoupling is right.** Plain maps, no dependency on
  `phoenix_kit_projects`, no FK — checked against the hub's `Extension.from_map/2`
  and it normalizes cleanly. `Code.ensure_loaded?/1` in the test catches the one
  failure mode (`normalize_tabs` silently *drops* a tab whose `:lv` won't load,
  so a typo'd module name would vanish with only a `Logger.warning` on the
  projects side).
- **`default_enabled: false`** is the correct default for an extension that
  exposes customer financial data.
- **The honest labeling is genuinely valuable** and consistently applied across
  the moduledoc, the tab name, and the in-page subtitle. It is preserved
  verbatim through all fixes.
- **`safe/1` degrading to the empty state** is the right call for a contributed
  tab — a billing DB hiccup must not take down the host project page.
- **Putting `rate_cents_per_hour` on this extension** so the bridge and the tab
  share one settings home is the correct seam.

## Post-merge changes

- `lib/phoenix_kit_billing/web/project_billing_live.ex` — issues 1–6.
- `lib/phoenix_kit_billing.ex` — `:limit` clause in `apply_invoice_filters/2`;
  `list_user_invoices/2` doc.
- `test/phoenix_kit_billing_test.exs` — off-router-mountability test; config
  schema type test.
- `test/phoenix_kit_billing/integration/context_test.exs` — `:limit` filter test.
- `priv/gettext/{default.pot,en,ru,et}` — 9 new msgids, fully translated.

## Verdict

**Approved with fixes.** The contract half of the PR is correct and was verified
against the real consumer. The tab LiveView shipped one finding that mattered —
the unlinked state enumerating every billing profile in the installation — plus
four smaller ones where it reimplemented shared billing UI (status colors, money
formatting) or skipped conventions the sibling CRM tab already followed (locale,
gettext). All six are fixed; two observations are recorded, not fixed.
