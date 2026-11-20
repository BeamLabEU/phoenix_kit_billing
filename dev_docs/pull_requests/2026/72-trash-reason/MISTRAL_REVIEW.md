# PR #72 review (Mistral)

`trash_order/2` takes an optional `:reason` (trimmed and cut at
`reason_max_length/0` by the shared `normalize_reason/1`), appended to the
**stored** `internal_notes` as `Trashed <YYYY-MM-DD HH:MM UTC>: <reason>` in
the same update as the trash fields.

## What I checked

- `trash_locked_order/2` now passes the whole `opts` through and pipes the
  changeset through the shared `put_reason_note/3` (the same helper
  `cancel_order/3` and `reinstate_order/3` use) with `locked.internal_notes` —
  the row read FOR UPDATE inside the transaction, so a note written after the
  caller read its struct is not dropped. Pinned by "a reason is appended to the
  stored internal notes".
- The reason is appended **after** `trash_changeset/2` already registered
  `bump_revision/1`; `internal_notes` is not a revision field and
  `put_reason_note/3` does not call `track_revision/1`, so a trash with a
  reason moves the revision exactly once — asserted in that same test
  (`Order.revision(row) == Order.revision(order) + 1`).
- Blank/nil/overlong reasons: blank normalizes to nil and touches nothing
  (loop over `[]`, `[reason: nil]`, `[reason: "   "]`); a `max + 50` reason is
  cut by graphemes (`String.slice/3`), asserted with a multi-byte "é".
- A refused trash (`:order_not_trashable`) writes no note — the cond returns
  before the changeset is built.
- The customer-facing `notes` field is untouched — asserted in the same test.
- API-only by design: the admin's Move to trash modal sends no reason (README
  says so); `reason_max_length/0`'s doc now names `trash_order/2`.

## Findings

- No BUGs found. No changes beyond the doc-wrap nits noted in the #71 review
  (fixed in the same review commit).

## Verification

Targeted: `trash_orders_test.exs` + `trash_fields_test.exs` — 51 tests, 0
failures. Full suite: 1671 tests, 0 failures. `mix precommit` clean.
