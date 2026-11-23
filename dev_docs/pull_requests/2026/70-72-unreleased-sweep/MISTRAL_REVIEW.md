# Sweep review of everything since 0.28.0 (Mistral)

Scope: the whole unreleased range `0.28.0..HEAD` (36 commits) — PRs #70
(`reinstate_order/3`), #71 (trash/restore move the revision) and #72
(`trash_order/2` reason), the two `mix.lock`-only lib-upgrade commits, and the
review-doc commits. No open PRs; #70-#72 already carry per-PR reviews, this
pass re-read the cumulative diff as one change and re-ran the gates.

## What I checked

- `reinstate_order/3` decides on the locked row (`lock_order_with_profile/1`,
  FOR NO KEY UPDATE): a stale struct, a vanished row (`:not_found`), an order
  in the trash (`:order_trashed`) and a non-cancelled status
  (`:order_not_reinstatable`) all refuse without writing. The reason note is
  appended to the **stored** `internal_notes` of that locked row.
- `Order.reinstate_changeset/3`: `track_revision/1` registers `bump_revision/1`
  first, the trail `prepare_changes` runs after it and replaces only
  `metadata["reinstated"]`; the cancellation trail and `sync` survive
  (`keep_owned_metadata/1` now keeps `@trail_metadata_keys`). The trail keys
  are not castable through `changeset/2` or `create_order/2` — pinned by the
  "cannot be forged" tests.
- Lock order holds: reinstate takes only the order row (step 7) and reads
  invoices without locking them, so it can never deadlock against a payment or
  refund, which take the invoice row first and then the order row. The race
  tests pin both commit orders with `Test.LockWait` on `pg_stat_activity`
  instead of a bare timeout.
- `settle_reinstated_order/1` runs inside the reinstate's transaction and
  re-locks the order through `maybe_mark_linked_order_paid/1` (now
  `lock_order_with_profile/1` instead of `get_order!/1`, so a vanished order
  is nil, not a raise): draft/pending are confirmed then paid, confirmed is
  paid; `:reinstated` and `:paid` jobs commit in the same single transaction
  (pinned by the steps test: one begin, one commit, two job inserts).
- Trash reason/revision: `put_reason_note/3` is shared by cancel, reinstate and
  trash; `internal_notes` is not a revision field, so a trash with a reason
  moves the revision exactly once (asserted). `updated_at` stays forced to
  the stored value on both trash and restore. `trashed_at` joining
  `@revision_fields` is what makes `sync` read `pending` again — pinned.
- UI: the reinstate button sits in the non-trashed branch of the actions (a
  trashed cancelled order gets Restore only), is gated on
  `@can_manage_orders`, the handler re-checks `Authz.authorize(:manage_orders)`
  (revocation on an open page is tested via `:sys.replace_state`), the modal
  reason textarea is capped at `reason_max_length/0`, and the Activity row
  logs `status`/`reinstated_status` but never the free-text reason (PII rule).
  Both order-event subscribers (`Web.Orders`, `Web.OrderDetail`) handle
  `:order_reinstated`; no other LiveView subscribes to order events.
- `OrderEvents`: `:reinstated` added to `@events`, the doc now says
  (order uuid, event) is not one occurrence (cancel→reinstate→cancel fires
  `:cancelled` twice) and that handlers need a catch-all clause; the worker
  test pins that a handler with no clause for an event fails its job.
- Compat shim delegates `reinstate_order/3` (the delegate drift test
  enumerates the shim's exports, so it is covered). Gettext: the 7 new msgids
  are in `default.pot` and all six locales with real translations (uk/et/ru
  reworded in the follow-up commits); pot-drift test passes.
- `mix.lock`-only commits: dep upgrades (bandit, certifi, etcher, ex_doc,
  telemetry, tessera, webtransport, …); `mix.exs` untouched, the
  `phoenix_kit >= 3.5.0 and < 4.0.0` pin unchanged (core-pin conformance test
  passes).

## Findings

- No BUGs found in the range.
- **IMPROVEMENT - LOW (fixed here)** — `Order.reinstated_status/1`'s whitelist
  and `reinstate_changeset/3`'s not-cancelled guard had no unit-level pin (the
  integration tests cover them through the context). Added a
  `reinstate_changeset/3 and reinstated_status/1` describe to
  `test/phoenix_kit_billing/schemas/order_test.exs`: the three whitelisted
  statuses, the `pending` fallback for a missing/hand-written trail, the
  status change + `cancelled_at` clearing, and the refusal of a non-cancelled
  order.

## Verification

- `mix test`: full suite green (1674 tests, 0 failures, integration included —
  `phoenix_kit_billing_test` up).
- `mix precommit`: clean — `deps.unlock --check-unused`, `hex.audit`, compile
  `--warnings-as-errors`, format, credo `--strict`, dialyzer (3 known skips
  from `.dialyzer_ignore.exs`, 0 unnecessary).
