# PR #52 recheck — User billing tabs in the avatar menu

Reviewed by Codex on 2026-10-13. Scope: PR #52 (`a05c7bf`), the dependency
update (`06377c6`), Claude's tests and release (`e22c2f2`), and the published
0.22.0 artifact.

## Verdict

No production defect found in the PR. Claude's implementation review and
release-state claims are confirmed. Added integration coverage for the actual
core dropdown rather than relying only on the tab predicate.

## Findings

### IMPROVEMENT - MEDIUM — The tests did not exercise the dropdown (fixed)

Claude's positive-path tests correctly catch an always-false shop gate, but
`Tab.user_menu?/2` alone does not establish that core loads the tabs, retains
them through its filtering, resolves their paths, or renders usable links.
The disabled-shop test also checked only the billing helper.

Added three database-backed tests using core's real dashboard registry and
`UserDashboardNav.user_menu_tab_links/1` with a registered shop fixture whose
enabled state comes from Settings. They establish:

- Both expected tabs load in order with absolute dashboard paths.
- Rendered links carry the host URL prefix and Russian locale, and labels use
  billing's translated catalogue.
- Turning the shop off removes the dropdown entries immediately, leaves the
  dashboard tabs intact, and turning it on restores the entries.
- Missing scope or an unregistered shop produces no billing dropdown entries.

The unit tests now also assert the exact tab ids (preventing vacuous success
if the tab list becomes empty) and check each disabled tab's predicate.
Both files run synchronously because they use global registries. Database
writes are sandboxed; the shop registration and host prefix are restored on
exit. Older cores still exclude tests through `:requires_core_user_menu`.

### NITPICK — Published release commit has a forbidden co-author trailer

Confirmed `e22c2f2` contains the trailer Claude reported. This violates the
project's commit convention but does not change package behavior. Preserved
the published commit and immutable `0.22.0` tag; removing the trailer would
rewrite public history. The review follow-up uses a compliant commit message.

## Compatibility and release evidence

- Resolved core: PhoenixKit 2.62.2. Its registry loads enabled modules' user
  tabs through `Tab.resolve_path/2`, applies permission/visibility filters,
  and evaluates `Tab.user_menu?/2`. Billing's callback matches this contract.
- Ecommerce's actual `permission_metadata/0` key is `"shop"`; billing requires
  no dependency on ecommerce. The legacy billing shim delegates
  `user_dashboard_tabs/0`, retaining the captured billing gate.
- Checked the published PhoenixKit 2.44.0 sources: `Tab.new/1` ignores the
  unknown option, and `Permissions.feature_enabled?/1` already exists. This
  change therefore does not need a higher dependency floor. This is a source
  compatibility check, not a complete test run against 2.44.0.
- Core explicitly registers the billing-profile list route; the order route
  comes from its tab's `live_view` declaration. Both menu destinations exist.
- GitHub reports PR #52 merged; the GitHub release and annotated `0.22.0` tag
  point to `e22c2f2`. At review start, local main and origin/main matched it.
- Hex reports 0.22.0 as the latest release, published at
  `2026-10-13T12:52:56.577504Z`, with no retirement. Downloaded its archive and
  compared all 125 packaged files byte-for-byte against `e22c2f2`: no differences.
  Archive SHA-256 matches Hex's published checksum:
  `2f7a630a48345d41c8f697f2c07b46970612c7f6992ee745c3eebe63810462e9`.

## Validation

- Original full suite: 820 tests, zero failures, four documented core-gap skips.
- Focused suite with the improvements: seven tests, zero failures.
- Final full suite: 823 tests, zero failures, four documented core-gap skips.
- `mix precommit`: passed (warnings-as-errors compilation, unused-lock check,
  Hex audit, format, strict Credo, and Dialyzer with the existing ignore list).
  Hex reported an expired authentication session and continued the public audit
  successfully. Authentication should be refreshed before a future publication;
  no publication was attempted in this review.

Only tests and review documentation changed. No version bump or further Hex
publication is needed for this follow-up.
