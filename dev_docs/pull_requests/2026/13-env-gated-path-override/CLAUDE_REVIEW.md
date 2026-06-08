# Code Review: PR #13 — Add env-gated path override for phoenix_kit deps (local dev)

**Reviewed:** 2026-06-08
**Reviewer:** Claude (claude-opus-4-8)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/13
**Author:** Max Don (mdon)
**Head SHA:** a835fd08ec53eb26c2a92537138a1db7902e9828
**Status:** Merged

## Summary

Adds a private `pk_dep/3` helper in `mix.exs` so `phoenix_kit*` deps can resolve
to a local checkout during cross-repo development without changing the published
dependency. The helper reads `<APP>_PATH` (the dep's app name upper-cased, plus
`_PATH`):

- **unset** → the existing Hex requirement, unchanged
- **set** → `{app, [path: <path>, override: true] ++ opts}`

`AGENTS.md` gains a "Local cross-repo development" section documenting the
convention. With the var unset, `mix deps.get` / `mix hex.publish` / CI resolve
exactly as before — nothing path-based ships.

## Issues Found

### 1. [BUG - MEDIUM] Empty-string env var produced a broken `path: ""` dep — FIXED
**File:** `mix.exs` lines 81–89 (original)
**Confidence:** 90/100

`System.get_env/1` returns `""` (not `nil`) when a var is *exported but empty* —
a common situation from `export PHOENIX_KIT_PATH=` in a shell script or a CI step
that sets the var unconditionally. The original `case` matched only `nil` for the
fallback, so an empty string fell into the `path ->` branch and produced
`{:phoenix_kit, [path: "", override: true]}`, which fails dep resolution with a
confusing path error instead of falling back to the published Hex pin.

**Fix applied:** match a non-empty binary for the path branch and let everything
else (`nil` *and* `""`) fall through to the Hex pin. This also collapsed the
redundant `nil when opts == []` / `nil` branches, since `{:phoenix_kit, "~> 1.7",
[]}` is already a valid Mix dep tuple — no need to special-case empty opts.

```elixir
case System.get_env(env_var) do
  path when is_binary(path) and path != "" ->
    {app, [path: path, override: true] ++ opts}

  _ ->
    {app, requirement, opts}
end
```

Verified with `mix deps`: unset → Hex pin, `PHOENIX_KIT_PATH=` → Hex pin (was
broken), `PHOENIX_KIT_PATH=../phoenix_kit` → local path dep.

### 2. [OBSERVATION] Docs overstate generality
**File:** `AGENTS.md` ("Local cross-repo development")
**Confidence:** 80/100

The section says "Set several at once to override multiple deps," but only
`:phoenix_kit` is currently routed through `pk_dep/3`; there are no sibling
`phoenix_kit_*` deps in `deps/0`. Exporting e.g. `PHOENIX_KIT_AI_PATH` is a no-op
today — the mechanism only works for deps actually wired through `pk_dep`. The
design is forward-looking and correct; the multi-dep claim is just aspirational
until a second dep is routed through the helper. No code change made.

### 3. [OBSERVATION] No CHANGELOG entry — intentional/correct
**Confidence:** 75/100

`AGENTS.md` lists a changelog step in the release flow, but this change is
dev-only and ships nothing (`unset => published pin`), so omitting a CHANGELOG
entry is the right call. Noted only for completeness; no action needed.

## What Was Done Well

- The path branch correctly drops the version requirement and adds
  `override: true` — exactly right for a `path:` dep that must win over any
  transitive Hex pin.
- `Unset = published pin` keeps `mix hex.publish` and CI byte-for-byte unchanged;
  the `package` files list carries nothing path-based.
- Self-documenting: inline comment in `mix.exs` plus an `AGENTS.md` section that
  explicitly warns against hand-editing a committed `path:` tuple (which would
  ship a broken package).

## Verdict

**Approved with fixes** — The design is clean and safe for publishing. One
robustness bug (empty-string env var) is now fixed and verified; the remaining
items are observations, not defects.
