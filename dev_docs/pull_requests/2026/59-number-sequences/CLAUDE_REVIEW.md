# PR #59 — Number orders, invoices, receipts and transactions from a counter

**Reviewed:** 2026-11-05
**Reviewer:** Claude (claude-opus-5-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/59
**Author:** timujinne
**Head SHA:** `5fbf43a`
**Status:** Merged; one finding fixed

## Summary

Independent of `CODEX_REVIEW.md`. The counter is sound: an `UPDATE ... RETURNING`
serializes takers, `ON CONFLICT` covers two first callers, and the savepoint retry
keeps a taken number from aborting a caller's transaction. Checked in the current
code: the unique constraints name the real `_uidx` indexes, so `number_taken?/2`
fires; `Regex.escape/1` output for a prefix with metacharacters matches in Postgres
(`A.B`, `A+B(1)`, `INV 2`, `A#B` and `A-B_C` were run); the 15-digit cap keeps
`String.to_integer/1` inside `bigint`.

## Issues Found

### BUG - MEDIUM — A blank number on update raised instead of returning a changeset — fixed

Codex fixed blank numbers on the create paths. The update paths still let one
through: `cast/3` turns `""` into a `nil` change, neither changeset requires the
number (a new row must not, as the context numbers it), and `number_floors/2` skips
a non-binary. Reproduced against the merged code:

    update_order(order, %{"order_number" => ""})
    ** (Postgrex.Error) 23502 (not_null_violation)

`update_invoice/2` raised the same way, and `cast/3` treats a whitespace-only number
as blank too. Both documents promise `{:error, changeset}` and a usable caller
transaction, and a raise delivers neither.

Fixed with `require_stored_number/1` in `Order.changeset/2` and
`Invoice.changeset/2`, applied to loaded rows only. Reachable only through the API,
since neither form has a number input. The tests cover `nil`, `""` and `"   "`, and
that a caller's transaction survives.

## Retained limitation

The renewal worker still holds the invoice counter across its provider charge, as
Codex and the `Migrations` moduledoc record. Not addressed here.

## What Was Done Well

- The lock order is written down where a host wrapping calls in a transaction will look.
- Real-connection tests for the races, not sandbox approximations.

## Verdict

Sound design. One gap on the update side, now closed.
