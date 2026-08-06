# GLM Review — css_sources/0 callback

Model: glm-5.2 via the z.ai endpoint, reviewer persona (two-stage). Read-only pass over `git diff main...fix/css-sources-callback`, with the compiler mechanism verified against core and against all four sibling modules.

Here is my review.

---

## Stage 1: Spec Compliance

The PR claims: billing is the only PhoenixKit module lacking `css_sources/0`; the host compiler collects sources via a `function_exported?/3` guard and emits `@source` lines; adding `def css_sources, do: [:phoenix_kit_billing]` makes Tailwind scan this package's templates. Verifying each claim against the real core code:

- **Guard claim — VERIFIED.** `compile.phoenix_kit_css_sources.ex:35` calls `mod.css_sources()` only `if Code.ensure_loaded?(mod) and function_exported?(mod, :css_sources, 0)`. A module without the callback contributes `[]` (`:36-39`), so no `@source` line is emitted — exactly the described failure mode.
- **Return-shape claim — VERIFIED.** `module.ex:295` declares `@callback css_sources() :: [atom() | String.t()]`. `compile.phoenix_kit_css_sources.ex:105-113` handles atoms: `:phoenix_kit_billing` → `find_dep_path/2` → `:hex` (no `path:` opt) → emits `@source "../../deps/phoenix_kit_billing";`. The list-of-atoms shape is correct.
- **Discovery reach — VERIFIED.** `PhoenixKitBilling` calls `use PhoenixKit.Module` (`phoenix_kit_billing.ex:43`), persisting `@phoenix_kit_module true` (`module.ex:519-520`). `module_discovery.ex:111-119` requires `:phoenix_kit` in the app's `applications`; billing's compiled `.app` lists `phoenix_kit` (Mix auto-infers it from the `runtime: true` dep in `mix.exs:114`). So `scan_beam_files/0` finds `PhoenixKitBilling` and the compiler will now invoke its callback. (Confirmed independently of the commit message's host verification.)
- **Sibling parity — VERIFIED.** All four siblings return exactly the bare app-name atom: `phoenix_kit_crm.ex:227`, `modules/emails/emails.ex:957`, `newsletters.ex:158`, `publishing.ex:629`. None returns more than the bare atom; billing matches precisely.
- **Templates actually ship — VERIFIED.** `mix.exs:160` packages `~w(lib priv .formatter.exs ...)`, so the `.ex`/`.heex` templates land in `deps/phoenix_kit_billing/lib/`; the emitted `@source` resolves to real files. The fix is end-to-end effective in a host.

**Spec Verdict:** PASS

---

## Stage 2: Code Quality

### NITPICK: No regression test, though the repo has a one-line callback-test pattern
**File**: `lib/phoenix_kit_billing.ex:131` (testable at `test/phoenix_kit_billing_test.exs:10`)
**Problem**: The repo already asserts behaviour callbacks directly — `test/phoenix_kit_billing_test.exs:10` does `assert Billing.module_key() == "billing"`. `css_sources/0` is the callback this whole fix is about, and it is the one that was silently missing. There is no parallel assertion. The siblings don't test it either, so this is convention-agnostic, but the bug class (a module quietly dropping the callback) is exactly what a one-liner guards against.
**Suggestion**: Add next to the `module_key` test: `test "css_sources/0 returns the billing app" do ... assert Billing.css_sources() == [:phoenix_kit_billing]`. Cheap, consistent with the existing file, and pins the atom shape the compiler depends on.
**Rationale**: Trivial to add; catches a deletion/rename regression that would otherwise resurface as the exact "Tailwind purges every billing class" outage this PR exists to fix.

### MINOR: No version bump or CHANGELOG entry — the fix cannot reach hosts via Hex as-is
**File**: `mix.exs:4` (`@version "0.5.2"`), `CHANGELOG.md` (no `0.5.3`/css entry)
**Problem**: The code change is correct, but `mix.exs` is still `0.5.2` — the *same* version that ships the bug. The most recent `CHANGELOG.md` entry is `[0.5.2] - 2026-08-05`. Without a version bump and publish, the patch sits on the branch and no host resolving `~> 0.5.2` ever receives it. The commit's own "Verified on a host running billing 0.5.2" shows the buggy release is already out in the wild.
**Suggestion**: Bump to `0.5.3` and add a `### Fixed` CHANGELOG line (e.g. "Billing's Tailwind classes were purged from host builds — the package never declared `css_sources/0`, so the host compiler emitted no `@source` line for it.") before cutting the Hex release.
**Rationale**: This is release hygiene, not a code defect — but the PR's stated intent ("fixes that") is only true for hosts once the fix is published, so flagging it under the "end-to-end in a host" lens.

**Note (verified clean, not a finding):** `@impl PhoenixKit.Module` on an optional callback (`module.ex:295`, `:504`) is valid — optional callbacks are still real callbacks, and all four siblings annotate the same line the same way (`@impl PhoenixKit.Module` before `def css_sources`). `__using__` declares `css_sources` `defoverridable` (`module.ex:568`, `:601`), so the override replaces the `[]` default cleanly with no warning. Placement (right after `route_module/0`, inside the "MODULE BEHAVIOUR CALLBACKS" block) matches CRM (`:226`) and Publishing (`:628`).

**Quality Summary:** 0 critical, 0 major, 1 minor, 1 nitpick
**Quality Verdict:** Ship

---

## Overall Verdict: PASS

The fix is correct, minimal, and exactly mirrors the established pattern in all four sibling modules. The core mechanism — `function_exported?/3` guard, atom→`@source "../../deps/<app>"` resolution, beam-attribute discovery gated on `:phoenix_kit` in `applications` — is verified against the actual core code, and the package ships its `lib/` so the emitted `@source` resolves to real templates. Stage 1 fully passes.

Before merging/cutting a release, consider (in priority order):
1. **(minor)** Bump to `0.5.3` + add a `### Fixed` CHANGELOG entry — otherwise the patch never reaches hosts pinned to `~> 0.5.2`.
2. **(nitpick)** Add a one-line `css_sources/0` assertion beside the existing `module_key/0` test as a regression guard.

Neither blocks merge of the code change itself.
