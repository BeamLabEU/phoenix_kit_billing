# PR #72 review

The context appends a normalized reason to the locked order’s internal notes in the same update as the trash fields. Tests cover stale notes, blank and overlong reasons, refused transitions and preservation of customer notes.

**IMPROVEMENT - MEDIUM** The PRs tested the reason and revision independently. The combined regression now checks the stored revision advances exactly once when trashing also appends a reason.
