# PR #70 review (Mistral)

`reinstate_order/3`: a cancelled order goes back to `metadata["cancelled_from"]`
(`"pending"` for pre-trail orders), with `metadata["reinstated"]` as the trail,
an optional reason appended to the stored `internal_notes`, the durable
`:reinstated` event, `:order_reinstated` / `:order_confirmed` / `:order_paid`
broadcasts, and the admin modal under `manage_orders`.

## What I checked

- The transition decides on the **locked** row (`lock_order_with_profile/1`,
  FOR NO KEY UPDATE), not the caller's struct: a stale struct cannot reinstate
  an order already reinstated (`:order_not_reinstatable`), and an order in the
  trash is refused with `:order_trashed` before anything is written. Covered by
  "decides on the stored status, not the stale struct's" and "an order in the
  trash, until it is restored".
- `reinstate_changeset/3` records the trail in a `prepare_changes` that runs
  after `bump_revision/1`, so the stored `cancelled_from` trail survives the
  revision bump; `changeset/2` still cannot cast the trail keys (verified against
  its cast list and `keep_owned_metadata/1`).
- `settle_reinstated_order/1` runs inside the same transaction and re-locks the
  order through `maybe_mark_linked_order_paid/1`, so a payment committing
  concurrently waits for the reinstate and pays the reinstated order; the race
  tests (`reinstate_race_test.exs`, using `Test.LockWait` on `pg_stat_activity`
  instead of a bare timeout) pin both commit orders.
- The revision moves on (status + trail changes), so a synced order reads
  `"pending"` again — tested. The `OrderEvents` doc now warns that (order uuid,
  event) is not one occurrence: cancel → reinstate → cancel fires `:cancelled`
  twice, so handlers key idempotency on the order's current status.
- UI: the button shows only for a cancelled, non-trashed order under
  `manage_orders`; the event handler re-checks the capability; the modal's
  reason textarea is capped at `reason_max_length/0`; the Activity row logs
  `status` and `reinstated_status` but never the free-text reason (PII rule).
- `errors.ex` gained `:order_not_reinstatable`; the compat shim delegates
  `reinstate_order/3`; gettext msgids are in `default.pot` and all six locales
  (pot drift test passes in the full suite).

## Findings

- No BUGs found.
- **NITPICK** — `AGENTS.md` and `Order`'s moduledoc picked up awkward mid-phrase
  line wraps from the merge edits ("...stays in the invoice / lists: ...",
  "...A trashed / order refuses..."). Rewrapped in the review commit; wording
  unchanged.

## Verification

`mix test` full suite: 1671 tests, 0 failures. `mix precommit` clean
(compile --warnings-as-errors, format, credo --strict, dialyzer,
deps.unlock --check-unused, hex.audit).
