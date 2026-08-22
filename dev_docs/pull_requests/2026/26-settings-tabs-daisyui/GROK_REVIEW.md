# Grok Review — PR #26 "Add a SettingsTabs component, drop the four duplicated strips, and fix the daisyUI tabs class"

**Merge commit:** 2756113
**Author:** mdon (fix/daisyui-tabs-box)
**Files:** `lib/phoenix_kit_billing/web/components/settings_tabs.ex` (new), plus the four settings LiveViews and their templates.

## Summary of the change

The billing settings tab strip was hand-rolled markup copied into
`settings`, `provider_settings`, `currencies` and `subscription_types` —
each hardcoding `tab-active` on its own entry, each using daisyUI 4's
`tabs-boxed`. A fifth page meant four edits, and a class rename needed
four edits in this module alone.

Now a single `<.settings_tabs>` renders through core's `<.nav_tabs>`. Tabs
use `:path` (not `:navigate`) so the strip still works against every 2.x
core: link keys live in a runtime map, and `:navigate` against an older
core would silently render dead buttons. Currencies keeps `class="tabs-sm"`
to match the original `tab-sm` strip.

## Findings

### 1. NITPICK — duplicate `alias PhoenixKit.Utils.Routes` in provider_settings.ex

Pre-existing, not introduced by the PR. The new import landed between the
two identical aliases. **Fixed** by dropping the earlier copy.

No component test for `settings_tabs/1`. The four templates are the
callers and the tab list is a single literal; a render test would mostly
repeat the component. Left as-is.
