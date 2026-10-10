# Code Review: PR #49 — Open the dashboard billing profile edit page on the profile, not a new one

**Reviewed:** 2026-10-10 (post-merge)
**Reviewer:** Claude (claude-sonnet-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/49
**Author:** timujinne (Tymofii Shapovalov)
**Merge:** 3c68f79

## Summary

Core routes the dashboard edit page as `/dashboard/billing-profiles/:uuid/edit`;
`UserBillingProfileForm` read only `params["id"]`, so every edit link rendered
the "New Billing Profile" form and saving it created a duplicate. The form now
reads `params["uuid"] || params["id"]`. The PR also makes saving a profile as
default clear the flag on the user's other profiles in the same transaction, and
makes `get_default_billing_profile/1` tolerate several defaults (most recently
updated wins) instead of raising `Ecto.MultipleResultsError`.

The claim checks out against the producer: `deps/phoenix_kit/lib/phoenix_kit_web/integration.ex`
declares `live "/dashboard/billing-profiles/:uuid/edit"` (both the localized and
the plain route). The ownership guard in `load_profile/2` still runs on the
resolved profile.

## Verification

- `mix test`: 816 tests, 0 failures, 4 skipped (the documented subscription chain gap).
- The new tests route the page by both `:uuid` and `:id`, assert the edit form
  loads the profile, that another user's profile is "Access denied", and that a
  save updates instead of inserting. Context tests cover create/update as
  default, a failing changeset rolling the demotion back, and duplicate legacy
  defaults.

## Findings

### NITPICK — Duplicate `alias PhoenixKit.Utils.Routes` (fixed)

`user_billing_profile_form.ex` and `billing_profile_form.ex` each aliased
`PhoenixKit.Utils.Routes` twice. Harmless, but noise in a file this PR touches.
Removed the second alias in both.

### NITPICK — No database-level guarantee of one default (not fixed)

`save_keeping_one_default/2` keeps the invariant inside a transaction, but two
concurrent saves of different profiles as default can still both commit. A
partial unique index on `(user_uuid) WHERE is_default` would close it, but it
means a V6 migration on a core-created table (with a demotion step first, like
V2) and a `CoreCompat`/`ExpectedSchema` coordination. The read side already
tolerates duplicates, so the cost of the race is low. Left on record rather than
added.

## Verdict

Approve. One cosmetic cleanup applied.
