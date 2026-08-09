# Code Review: PR #16 — Make the subscriptions search live, like every other billing list

**Reviewed:** 2026-08-05
**Reviewer:** Claude (claude-opus-5[1m])
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/16
**Author:** Timujeen (timujinne)
**Head SHA:** dde17b24b9e61aa3e9326b56a0fcb41d759344d2
**Merge SHA:** 2d01513bf5ecaec3116daee69967fefc5b1d0e1c
**Status:** Merged

## Summary

The subscriptions list was the only billing list whose search required
pressing Enter. This adds `phx-change="search"` and `phx-debounce="300"` to
the form, gives it an `id`, and passes `replace: true` to the `push_patch`
in the existing handler.

## Issues Found

None. Twelve lines, and each one is right:

- `handle_event("search", %{"search" => search}, socket)` already destructures
  what `phx-change` sends, so no handler signature change was needed.
- The form keeps `phx-submit="search"` alongside `phx-change`, so Enter and
  the magnifying-glass button still work.
- `phx-debounce="300"` matches the value the other three lists use.
- The added `id` is what LiveView needs to track the form across patches.
- `replace: true` is the non-obvious part and the comment explains it
  correctly: without it a debounced box pushes one history entry per typing
  pause, so Back walks the query backwards a few characters at a time
  instead of leaving the page.
- The search value comes from `@search` via `handle_params`, and LiveView
  does not clobber the value of a focused input during a patch, so typing is
  not interrupted by the round trip.

### 1. [IMPROVEMENT - MEDIUM] The three sibling lists have the bug this PR fixes — FIXED
**File:** `lib/phoenix_kit_billing/web/{orders,invoices,transactions}.ex`
**Confidence:** 93/100

The PR's premise is "like every other billing list", and the other three
lists were already `phx-change` + `phx-debounce="300"`. But none of them
passes `replace: true`:

```elixir
def handle_event("filter", params, socket) do
  new_params = build_url_params(socket.assigns, params)
  {:noreply, push_patch(socket, to: Routes.path("/admin/billing/orders?#{new_params}"))}
end
```

So orders, invoices and transactions all have exactly the Back-button
behaviour this PR diagnosed — the subscriptions list is now the only one
without it, which inverts the consistency the PR was aiming at.

**Fix applied:** the same `replace: true` and the same explanatory comment on
all three, so "like every other billing list" is now true in both directions.

## What Was Done Well

The comment carries the reasoning rather than the mechanics — `replace: true`
is the kind of flag that gets removed by the next person as redundant unless
someone writes down what it prevents, and this one says exactly that. Adding
the form `id` unprompted is the right instinct. Correctly scoped: it changes
the one list that differed and nothing else.

## Verdict

**Approved.** Correct as merged. The follow-up applies the same fix to the
three sibling lists so the consistency claim holds.
