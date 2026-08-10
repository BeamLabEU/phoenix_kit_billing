# PR #9 Review — Wire per-module Gettext backend for sidebar tab labels

**Repo:** BeamLabEU/phoenix_kit_billing
**Branch:** `timujinne:main` → `BeamLabEU:main`
**Commits:** 1 (`30d32f2` Add per-module Gettext backend for sidebar tab labels)
**Reviewer:** Claude (Opus 4.7)
**Outcome:** CLOSED unmerged 2026-05-11 — see "Outcome" at the bottom.

## Verdict

**APPROVE** (after re-review of `c935729`) — both HARD RULE violations resolved. The substantive wiring (Gettext backend module, tab attributes, catalogues, smoke tests) is solid.

*Original verdict was REQUEST CHANGES; superseded after the fix commit landed. See "Re-review" section at the bottom.*

## Summary of changes

- New module `PhoenixKitBilling.Gettext` (`use Gettext.Backend, otp_app: :phoenix_kit_billing`).
- All 13 `Tab.new!/1` calls in `lib/phoenix_kit_billing.ex` (`admin_tabs/0`, `settings_tabs/0`, `user_dashboard_tabs/0`) now carry `gettext_backend: PhoenixKitBilling.Gettext` and `gettext_domain: "default"`.
- New manually-maintained `priv/gettext/default.pot` with 11 unique msgids (Billing, Dashboard, Orders, Invoices, Transactions, Subscriptions, Subscription Types, Billing Profiles, Currencies, Payment Providers, My Orders).
- New `priv/gettext/{en,ru,et}/LC_MESSAGES/default.po` — full coverage for every msgid.
- New `test/phoenix_kit_billing/i18n_test.exs` (4 tests, gated by `:requires_phoenix_kit_i18n_api` moduletag).
- `test/test_helper.exs` rewritten to detect `PhoenixKit.Dashboard.Tab.localized_label/1` and exclude i18n tests when the API is absent.
- `mix.exs`: `:gettext` added to `extra_applications`, `{:gettext, "~> 1.0"}` dep, `priv` added to `files:` in `package/0`.
- Substantial `mix.lock` churn (see Findings).

## Findings

### BUG - CRITICAL — `@version` bump in `mix.exs`

```diff
- @version "0.1.4"
+ @version "0.1.5"
```

`mix.exs:4` violates the standing HARD RULE: *"Never bump `@version` in `mix.exs` and never write `CHANGELOG.md` entries"* — applies uniformly to `phoenix_kit` core and every `phoenix_kit_<x>` child module. The maintainer derives version bumps from commit messages at release time. **Revert to `0.1.4`.**

### BUG - CRITICAL — New `CHANGELOG.md` entry

```diff
+## [0.1.5] - 2026-05-08
+
+### Added
+- Per-module Gettext backend (`PhoenixKitBilling.Gettext`) with `en`/`ru`/`et` catalogues …
```

Same HARD RULE — `CHANGELOG.md` ownership is maintainer-only. **Revert the 5-line addition.** The information is already captured in the commit body, which is what the maintainer reads at release time.

### IMPROVEMENT - MEDIUM — `mix.lock` churn unrelated to the gettext wiring

The lockfile picks up incidental bumps that have nothing to do with this PR:

- `bandit` 1.10.4 → 1.11.0
- `beamlab_countries` 1.0.7 → 1.0.8
- `db_connection` 2.9.0 → 2.10.0
- `decimal` 2.3.0 → 3.0.0 (**major version bump** — requires confirmation it doesn't break callers)
- `ecto` 3.13.5 → 3.13.6
- `oban` 2.21.1 → 2.22.1
- `phoenix` 1.8.5 → 1.8.7
- `phoenix_live_view` 1.1.28 → 1.1.30
- `postgrex` 0.22.0 → 0.22.1
- `spitfire` 0.3.10 → 0.3.11
- `swoosh` 1.24.0 → 1.25.1
- `tesla` 1.16.0 → 1.17.0
- new transitive deps: `aws_regions`, `backblaze_regions`, `tigris_regions`

This looks like collateral from running `mix deps.get` or `mix deps.update` with a stale lock. Recommend isolating to *only* the entries strictly needed to resolve `{:gettext, "~> 1.0"}` (which `phoenix_kit ~> 1.7` already requires transitively — it's likely already in the lock). A clean follow-up would revert the unrelated entries; if the bumps are genuinely needed they belong in a separate `Update dependencies` PR with its own justification. The `decimal` major bump in particular shouldn't sneak in via an i18n PR.

### IMPROVEMENT - MEDIUM — `priv` was not previously packaged

```diff
- files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
+ files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
```

Correct and necessary — without this the translation catalogues would not ship with the Hex package and locale switching would do nothing in consumer apps. Flagged here only because it's a behaviour-relevant change that's easy to miss in a "tabs only" PR. ✓ Approved as written.

### NITPICK — Redundant `alias PhoenixKitBilling` in `i18n_test.exs`

```elixir
alias PhoenixKit.Dashboard.Tab
alias PhoenixKitBilling
alias PhoenixKitBilling.Gettext, as: BillingGettext
```

`alias PhoenixKitBilling` is a no-op — the module already resolves under its full name and there's no nesting being shortened. Safe to delete; not blocking.

### NITPICK — i18n smoke test could iterate every locale/label pair

`describe "Tab.localized_label/1 against the module's catalogue"` only checks the parent `:admin_billing` tab against ru/et. With 11 unique msgids and 2 non-default locales (22 pairs), a single `for {locale, expected} <- [...]` loop would catch missing translations earlier. Adequate as a smoke test as written, but a tiny upgrade would push this from "wiring works" to "all translations resolve".

## Verifications performed

- `git -C phoenix_kit_billing show origin/main:lib/phoenix_kit_billing.ex | grep -c 'Tab.new!'` → **13**
- `git -C phoenix_kit_billing show origin/main:lib/phoenix_kit_billing.ex | grep -c 'gettext_backend: PhoenixKitBilling.Gettext'` → **13** ✓ Every tab wired.
- All 11 msgids in `default.pot` are present in `{en,ru,et}/LC_MESSAGES/default.po` with non-empty `msgstr` for ru/et ✓
- ru/et translations spot-checked for accuracy — Estonian "Püsitellimused" (standing/recurring orders) for "Subscriptions" is a thoughtful choice that disambiguates from "Tellimused" (Orders) ✓
- `test_helper.exs` gracefully degrades when `PhoenixKit.Dashboard.Tab.localized_label/1` is absent ✓

## Out of scope (acknowledged)

The bigger billing i18n debt (~394 raw strings in `provider_settings/print` templates and similar) is explicitly NOT in this PR. That belongs in a follow-up; do not gate this merge on it.

## Counts

- BUG - CRITICAL: 2 (`@version` bump, `CHANGELOG.md` entry)
- BUG - HIGH: 0
- BUG - MEDIUM: 0
- IMPROVEMENT - HIGH: 0
- IMPROVEMENT - MEDIUM: 2 (`mix.lock` churn, `priv` packaging note)
- NITPICK: 2

## Required actions to merge

1. ~~Revert `@version` in `mix.exs` to `0.1.4`.~~ ✅ Resolved in `c935729`.
2. ~~Delete the new `## [0.1.5] - 2026-05-08` block from `CHANGELOG.md`.~~ ✅ Resolved in `c935729`.
3. (Strongly recommended, non-blocking) Reset `mix.lock` to only the entries needed for `:gettext`; isolate the rest into a separate dep-update PR.

## Re-review (commit `c935729`)

Verified on 2026-05-11:

- `mix.exs` net diff vs `BeamLabEU:main` contains only gettext changes (`:gettext` in `extra_applications`, `{:gettext, "~> 1.0"}` dep, `priv` in package files). No `@version` change. ✓
- `CHANGELOG.md` no longer appears in the cumulative PR diff — the `## [0.1.5]` block is fully reverted. ✓
- Fix commit message: clean action-verb start ("Revert"), no AI mention. ✓

Verdict updated to **APPROVE**. GitHub re-review posted as a comment ([pullrequestreview-4261205377](https://github.com/BeamLabEU/phoenix_kit_billing/pull/9#pullrequestreview-4261205377)) — `gh pr review --approve` blocked because the authenticated user is also the PR author, so the explicit verdict lives in the comment body.

## Outcome — closed unmerged (2026-05-11)

Recorded after the fact; the review above ends at the APPROVE verdict.

The PR was closed the same day without merging: `30d32f2` is tree-identical
to `f12867c`, which had already reached `BeamLabEU:main` two days earlier via
[PR #8](https://github.com/BeamLabEU/phoenix_kit_billing/pull/8) (merged
2026-05-09, merge commit `343878c`). Nothing in it was new. Its review lives in
`../8-per-module-i18n/`, and the follow-ups it raised are tracked there.

Consequence for the two HARD RULE findings above: they describe code that is in
`main` — the `@version` bump and the `## [0.1.5] - 2026-05-08` block shipped
inside `f12867c` via PR #8, which the PR #8 review did not flag. The revert
`c935729` only ever existed on this closed branch, so "Resolved" means resolved
on a branch that was thrown away. `CHANGELOG.md` still carries the `[0.1.5]`
entry; releases have since moved on to 0.6.0, so it stays as history rather than
being retro-reverted.
