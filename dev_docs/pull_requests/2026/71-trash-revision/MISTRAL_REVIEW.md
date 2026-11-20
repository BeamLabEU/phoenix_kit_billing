# PR #71 review (Mistral)

Trashing and restoring an order now advance its revision (`trashed_at` joined
`@revision_fields`; `trash_changeset/2` and `restore_changeset/1` call
`track_revision/1`), while `updated_at` is still forced to its stored value.

## What I checked

- `trashed_at` is in `@revision_fields`, so `revision_relevant?/1` fires and
  `bump_revision/1` (FOR NO KEY UPDATE on the row the caller already holds
  FOR UPDATE — same transaction, no new lock ordering) lifts the stored
  revision by exactly 1. `keep_owned_metadata/1` keeps `sync` and the
  trail keys, so the mark goes stale in exactly the intended way:
  `Order.sync/1` reports `"pending"` after a trash/restore — pinned by
  "an order an external system holds reads as pending again".
- `keep_updated_at/1` still forces `updated_at` to `changeset.data.updated_at`;
  on the locked row that is the stored value. Both trash and restore tests set
  `updated_at` to 2020 and assert it survives.
- `changeset/2` still cannot cast `trashed_at`/`trashed_by_uuid` (verified in
  its cast list), so only the two dedicated changesets move them.
- The schema test now builds a `state: :loaded` struct, because
  `track_revision/1` on a `:built` struct would stamp `metadata["revision"]`
  into the changes — the trash only ever gets stored rows, and the test says so.
- `put_order_sync/2` is untouched and still writes only `metadata["sync"]`.

## Findings

- No BUGs found.
- **NITPICK** — merge left awkward line wraps in `AGENTS.md` and `Order`'s
  Trash moduledoc paragraph; rewrapped in the review commit.

## Verification

Targeted: `trash_orders_test.exs` + `trash_fields_test.exs` — 51 tests, 0
failures. Full suite: 1671 tests, 0 failures. `mix precommit` clean.
