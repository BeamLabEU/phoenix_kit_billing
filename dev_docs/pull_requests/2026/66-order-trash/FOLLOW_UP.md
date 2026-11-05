# Follow-up for PR #66

2026-11-05 — Claude review.

- **IMPROVEMENT - MEDIUM: Estonian strings — fixed.** Needs a native speaker's check.
- **IMPROVEMENT - MEDIUM: legacy delegates — fixed**, with a test.
- **NITPICK: V8 moduledoc — fixed.** The release notes must tell hosts to run V8 first.
- **Pre-existing: 80 msgids missing from the `.pot` — fixed**, with the seven flashes from
  #65 (87 in all), translated into ru, uk and et, and a new guard in `pot_drift_test.exs`.
  Needs a native speaker's check. `de` and `fr` stay partial by design.
- **Wrong plural in `subscription_types.html.heex` — fixed.**
