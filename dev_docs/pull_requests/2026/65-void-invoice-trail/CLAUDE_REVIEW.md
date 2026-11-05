# PR #65 — Void and cancel trail, and locked-row rewrites for void-safe invoice and order changes

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/65
**Author:** timujinne
**Head SHA:** `2dcf28b`
**Status:** Merged; all findings fixed

## Summary

A careful change. Moving each decision onto the locked row closes real races, and
keeping a charge that lands on a void invoice on the trail, instead of failing the
webhook, is the right call for money only an operator can return. Refusals returned
as values keep a caller's transaction usable throughout.

## Issues Found

### BUG - MEDIUM — Free-text reasons were written to the activity log — fixed

`AGENTS.md` is explicit: log uuids, statuses, amounts, currency codes, document numbers
and counts only, "never email, phone, names, card data, tokens or free text".
`void_invoice` and `cancel_order` put the operator's typed reason into activity
metadata, under a comment claiming it was not customer data. An operator's note is
exactly where a customer's name lands, and the rule has no such exception. The order
path also logged straight from `params["reason"]`.

Removed from both, along with both `put_reason` helpers. Nothing is lost: the reason
stays in `metadata["void"]` and in the order's `internal_notes`. The two tests that
asserted the reason in the log now assert its absence.

If the audit log should carry reasons, the rule in `AGENTS.md` needs changing first.

### IMPROVEMENT - MEDIUM — Estonian strings shipped as raw English — fixed

See #66's review: the same gap across both PRs, fixed once. `ru` and `uk` were
translated here; `et` was left as copies of the msgid, which an empty-string check
does not notice.

### NITPICK — Hard-coded English flashes in `invoice_detail/actions.ex` — fixed

"Invoice voided", "Refund recorded successfully" and five others bypassed gettext. They
predate this PR (d100cc2). All seven now go through gettext, translated with #66's
catalogue pass.

## Checked and cleared

**`in_savepoint/1` with `prepare_changes`.** Suspected that `Order.track_revision`'s
`prepare_changes` would make Ecto nest a transaction whose rollback aborts the outer
one, so `ROLLBACK TO SAVEPOINT` would raise. It does not: a probe returned a real
changeset and left the caller's transaction usable, because `Ecto.Repo.Schema` skips
the wrapper when `adapter.in_transaction?/1` is true. That guard is in every Ecto the
old `~> 3.12` pin admitted: 3.12.0, 3.12.6, 3.13.0 through 3.13.5 and 3.14.0 through
3.14.3 were read. An earlier version of this note called 3.12.x unverified, because
those packages were not at hand; they have since been fetched and checked. The pin is
now `~> 3.13` at the maintainer's request, which is a choice and not a requirement of
this code.

## What Was Done Well

- `keep_void_trail/1` and the cancel keys make the trail unforgeable through a form.
- `update_order/2` applies attrs to the stored row, so a stale form cannot undo a cancel.

## Verdict

Strong. One written rule was broken, and that is now fixed.
