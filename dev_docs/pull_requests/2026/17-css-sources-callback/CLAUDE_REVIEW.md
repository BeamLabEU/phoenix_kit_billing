# Code Review: PR #17 — Implement css_sources/0 so hosts keep the billing classes

**Reviewed:** 2026-08-06
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/17
**Author:** timujinne (branch `fix/css-sources-callback`)
**Head SHA:** a520434
**Merge SHA:** 32a65f0
**Status:** Merged

## Summary

Billing was the only PhoenixKit module not implementing the optional
`css_sources/0` callback. Core's `:phoenix_kit_css_sources` compiler collects the
callback from every discovered module behind a `function_exported?/3` guard, so
billing contributed nothing, no `@source` line was written to the host's
`assets/css/_phoenix_kit_sources.css`, and Tailwind purged every class used only
inside billing's templates from the host bundle. The PR adds
`def css_sources, do: [:phoenix_kit_billing]` plus a regression test, and carries
GLM's pre-merge review.

The change itself is correct, minimal, and matches all four sibling modules. I
re-verified the mechanism end to end against `deps/phoenix_kit`:

- `Mix.Tasks.Compile.PhoenixKitCssSources.run/1:35` guards on
  `function_exported?(mod, :css_sources, 0)` — the described failure mode is real.
- `format_source/2:105-113` maps the atom through `find_dep_path/2` to
  `@source "../../deps/phoenix_kit_billing";` (or the host's `path:` value).
- `ModuleDiscovery.ebin_depends_on_phoenix_kit?/1` requires `:phoenix_kit` in the
  app's `applications`; billing's compiled `.app` lists it, so discovery reaches
  `PhoenixKitBilling`.
- `mix.exs:160` packages `lib`, and every `.heex` in this repo lives under `lib/`,
  so the emitted `@source` resolves to real templates in a Hex install.

What the PR — and GLM's review — missed is that `css_sources/0` is not the only
place this module answers that question, and that the guard which made the bug
silent guards several other callbacks too.

## Issues Found

### 1. [BUG - MEDIUM] The compat shim doesn't delegate `css_sources/0`, so the legacy namespace still has the bug — FIXED
**File:** `lib/phoenix_kit_billing/compat/billing.ex` lines 12-25
**Confidence:** 85/100

`PhoenixKit.Modules.Billing` is a `defdelegate` shim that re-exports the module
surface under the pre-migration namespace, and it already carries the whole
`PhoenixKit.Module` callback set — `module_key`, `module_name`, `route_module`,
`permission_metadata`, `admin_tabs`, `settings_tabs`, `user_dashboard_tabs`,
`get_config`, `version`, `required_modules`, `enabled?`. It is a module the
registry can genuinely hold: `ModuleDiscovery.discover_external_modules/0` merges
beam-scanned modules with `Application.get_env(:phoenix_kit, :modules, [])`, and
the CSS compiler's own zero-sources error message tells operators to
`set config :phoenix_kit, modules: [...]` as the fallback. A host that registered
billing that way resolves the *shim*, and `function_exported?(shim, :css_sources, 0)`
is false — so PR #17 fixed the bug on one of the module's two faces.

One more callback was already missing on the shim for the same reason, collected
by core with the identical fail-open guard: `notification_types/0`
(`Notifications.Types.external_types/0:275`) — billing's entire notification tree
(`billing`, `invoices`, `your_billing`) never registers. `module_stats/0`
(`phoenix_kit_web/live/modules.html.heex:797`) is resolved the same way but was
already delegated, under the shim's "Utilities" heading rather than with the
other module callbacks.

**Fix applied:** `css_sources/0` and `notification_types/0` delegated, with a
comment stating why the gap is silent.

Reachability is why this is MEDIUM rather than HIGH — it needs a host on the
config fallback with the legacy module name. But that is exactly the population
the shim exists for, and the failure mode is the same invisible one the PR was
written to close.

### 2. [IMPROVEMENT - MEDIUM] The compat drift test only guards one direction — FIXED
**File:** `test/phoenix_kit_billing/compat_delegate_test.exs` lines 45-68
**Confidence:** 95/100

`compat_delegate_test.exs` asserts that every function the shim exports still
exists on the target — it catches a *rename or removal* on `PhoenixKitBilling`.
It cannot catch an *addition*: a new callback on the target that nobody
re-exported. That is precisely issue 1, and precisely the shape of PR #17 itself,
so the existing guard was structurally incapable of flagging either. AGENTS.md
lists "no compat-module drift tests" as remaining deferred work; this is the half
that was missing.

**Fix applied:** a reverse-direction test pinning the zero-arity surface core
resolves on a registered module (the `PhoenixKit.Module` callbacks plus the two
duck-typed hooks). It asserts the shim re-exports everything `PhoenixKitBilling`
actually implements, and skips anything the target doesn't implement, so it
doesn't demand delegates for defaults the module never overrode.

### 3. [NITPICK] The new test pinned a duplicated literal rather than the contract — FIXED
**File:** `test/phoenix_kit_billing_test.exs` lines 18-25
**Confidence:** 70/100

`assert Billing.css_sources() == [:phoenix_kit_billing]` is a good regression
guard for *deletion* — the `use PhoenixKit.Module` default returns `[]`, so
dropping the callback fails the test. But the atom itself is a second copy of a
constant whose only meaning is "the OTP app name the compiler will look up in the
host's deps"; if the package were ever renamed, code and test would be edited
together and the assertion would still pass while the emitted `@source` pointed
at a directory that no longer exists.

**Fix applied:** also assert against `Application.get_application(Billing)`, which
pins the actual contract. The literal assertion is kept alongside it so the test
still documents the expected value.

### 4. [NITPICK] `notification_types/0` was missing its `@impl` — FIXED
**File:** `lib/phoenix_kit_billing.ex` lines 194-209
**Confidence:** 80/100

Every other behaviour callback in the module carries `@impl PhoenixKit.Module`;
`notification_types/0` did not, and its `@doc` described it as "duck-typed". It
is a declared optional callback (`module.ex:502`), not duck typing — the
`function_exported?/3` lookup is how core *collects* it, not what makes it
informal. Without the annotation nothing marks it as part of the behaviour
contract, which is the same reading error that let `css_sources/0` go unnoticed.

**Fix applied:** added `@impl PhoenixKit.Module` and corrected the doc wording.

### 5. [OBSERVATION] AGENTS.md documented the callback as implemented the whole time — FIXED
**File:** `AGENTS.md`, "Tailwind CSS Scanning"
**Confidence:** 95/100

`git log -S "Tailwind CSS Scanning" -- AGENTS.md` traces the section to `1ef4068`
— the initial scaffolding commit. So the repo's own agent-facing documentation
asserted "This module implements `css_sources/0` returning `[:phoenix_kit_billing]`"
for the entire life of the package, while the code never did. Any reviewer or
agent checking the doc got a confirmation instead of a discrepancy. The section
also mis-attributed the mechanism to "PhoenixKit's installer" writing to
"the parent's `app.css`"; it is a Mix **compiler** that regenerates
`assets/css/_phoenix_kit_sources.css` on every compile.

**Fix applied:** rewrote the section with the real mechanism, an explicit note
that the callback fails open (with this incident as the example), and the
path-dep caveat in observation 6.

### 6. [OBSERVATION] Correctly *not* adding core's `@source_root` path-dep fallback
**File:** `lib/phoenix_kit_billing.ex` line 131
**Confidence:** 90/100

Core's `@callback css_sources` doc offers a path-dep-friendly variant:

```elixir
@source_root Path.expand(Path.join(__DIR__, "../.."))
def css_sources, do: [:phoenix_kit_publishing, @source_root]
```

Copying that here would be a bug, and it is worth recording before someone
"completes" the PR with it. The example assumes the callback lives at
`lib/<app>/<app>.ex`, where `../..` from `__DIR__` is the package root. Billing's
callback is in `lib/phoenix_kit_billing.ex`, so `__DIR__` is `<pkg>/lib` and
`../..` resolves to the *parent* of the package — `deps/` in a Hex install —
emitting an `@source` across the entire dependency tree.

It is also unnecessary: `find_dep_path/2` reads the host's `mix.exs` dep tuple and
uses its `path:` value when present, so the bare atom already handles path deps
and the `<APP>_PATH` override. The bare atom is what all four siblings return.
Noted in AGENTS.md; no code change.

## What Was Done Well

- The fix is the smallest correct one and matches the established pattern exactly
  rather than inventing a billing-specific variant.
- The inline comment on `css_sources/0` explains the *consequence* of the callback
  being absent, not what the line does — which is the only thing a future reader
  needs, given the failure is invisible at the call site.
- The follow-up commit (`a520434`) added the regression test in response to GLM's
  review rather than deferring it, and its comment correctly identifies why the
  failure mode is hard to trace back (symptom surfaces in a different repo).
- GLM's pre-merge review verified the core mechanism against actual core source
  rather than the PR description, including the `defoverridable`/`@impl`
  interaction — that part needed no re-checking.

## Verdict

**Approved with fixes.** The PR's own change is correct and I found nothing wrong
with it. Everything above is the same bug class in the places the PR didn't look:
the compat shim that presents the same callbacks under the legacy namespace, and
the drift test whose one-directional design could never have caught an added
callback. All findings are fixed in this release; observation 6 is recorded as a
caveat rather than changed.
