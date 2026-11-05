# Follow-up for PR #65

2026-11-05 — Claude review.

- **BUG - MEDIUM: free text in the activity log — fixed.** The reason stays on the
  invoice and order; the tests assert it is absent from the log.
- **IMPROVEMENT - MEDIUM: Estonian strings — fixed** with #66. Needs a native speaker's
  check.
- **NITPICK: untranslated flashes in `actions.ex` — not fixed**, pre-existing.
- **Open:** the `in_savepoint/1` clearance is unverified on Ecto 3.12.x.
