# Follow-up for PR #69

2026-11-12 — Claude review.

- **IMPROVEMENT - MEDIUM: retry queued for any paid subscription invoice — fixed.**
  `resume_paid_subscription/1` now queues the retry only when
  `SubscriptionCharge.period_paid?/1` holds for the past-due subscription. New test:
  "paying an invoice of another period queues no retry off the schedule".
- **NITPICK: past-due query before the transaction check — fixed.** The
  `in_transaction?/0` check now runs first.
- **NITPICK: a declined payment-triggered retry cannot reschedule itself — not fixed.**
  The retry scheduled earlier still stands. See the review.
- **NITPICK: CHANGELOG entry in the feature PR — left for the release commit**, which
  should say "the period's invoice".
