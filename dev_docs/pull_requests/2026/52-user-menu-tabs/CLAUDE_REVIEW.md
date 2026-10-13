# PR #52 Review — Add My Orders and Billing Profiles to the avatar menu beside a shop

**Reviewed:** 2026-10-13
**Reviewer:** Claude (Sonnet 5.5)
**PR:** #52 — `timujinne:user-menu-tabs` → `main`, merged as `a05c7bf` (head `1b5dd45`)
**Author:** timujinne
**Status:** Merged. Review follow-up applied on `main`.

## Summary

Flags both user-dashboard tabs with the `Tab` option `user_menu:` so core's
avatar dropdown lists them, gated by `user_menu_with_shop?/1`, which answers
`Permissions.feature_enabled?("shop")` (duck-typed; billing does not depend on
`phoenix_kit_ecommerce`). Declares the new core call in `CoreCompat`, adds a
`:requires_core_user_menu` test exclusion for cores without `Tab.user_menu?/2`,
and documents it in AGENTS.md.

## Verification against core (2.62.2, the resolved version)

- `Tab.new!/1` stores a 1-arity function under `metadata[:user_menu]`
  (`put_user_menu/2`); an older core never reads the attr, so the "costs no core
  floor" claim holds — the gate is never called there.
- `Registry.get_user_menu_tabs/1` calls `Tab.user_menu?/2` after the sidebar's
  permission/visibility filtering, and requires `fun.(scope) == true`, so the
  strict boolean return of `user_menu_with_shop?/1` is correct. Core also rescues
  raises and catches exits from the gate; the extra `rescue` here is harmless.
- Relative paths (`"billing-orders"`) are resolved to `/dashboard/…` by
  `Tab.resolve_path/2` at load, so core 2.62.2's "relative path crashes the
  dropdown" fix does not apply to these tabs.
- `ModuleRegistry.feature_enabled_checks/0` keys on `permission_metadata().key`;
  the ecommerce module's key is `"shop"` (`/workspace/phoenix_kit_ecommerce`), so
  the duck-typing matches the real producer.
- `Permissions.feature_enabled?/1` returns `false` for an unregistered key, so a
  host without ecommerce gets no entries — the intended behavior.

## Issues Found

### IMPROVEMENT - MEDIUM — Only the negative path was tested (fixed)

`user_menu_tabs_test.exs` proved the gate answers `false` with no shop. A
`user_menu_with_shop?/1` that always returned `false` (a typo in the key, a
wrong function) passed every test while the feature silently never appeared.

**Fix:** two tests register a stand-in `"shop"` module in `ModuleRegistry`
(unregistered in `on_exit`) and assert the tabs reach the dropdown while it is
enabled and leave it when it reports disabled. The file is now `async: false`
because the registry is global.

### NITPICK — Gate ignores `scope`

`user_menu_with_shop?/1` discards its argument. That is intended (a storefront
existing is not per-user), and the `@doc` says so; no change.

### NITPICK — `CoreCompat` lists `feature_enabled?/1` under unguarded `runtime_calls`

The function is called inside a `rescue`, so an `UndefinedFunctionError` on a
core without it degrades to "no entries". Keeping it in the unguarded list is the
stricter, safer choice for a boot report. No change.

## What Was Done Well

- The gate is a named public function captured with `&__MODULE__.f/1`, so the
  test compares the function identity rather than re-deriving behavior.
- Failure mode on an old or shop-less core is "nothing appears", never a crash.
- `test_helper.exs` excludes the new tests via `function_exported?/3` instead of
  assuming a core version, matching the existing i18n exclusion.

## Verdict

**APPROVE.** No bugs; one test-coverage gap closed.
