# Code Review: PR #37 — Diagnose a bad database connection instead of timing out

**Reviewed:** 2026-09-08
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/37
**Author:** Max Don (mdon)
**Head SHA:** 934a589 (via merge-base 7def9e6)
**Status:** Merged

## Summary

Replaces `test_helper.exs`'s `psql -lqt` database-existence probe with an
optional call into a core helper, `PhoenixKit.TestSupport.PostgresPreflight`,
guarded by `Code.ensure_loaded?/1`. The stated motivation: `psql -lqt` ran as
the shell user over a unix socket and could report "the database exists"
while the *configured role* (over TCP, with its own credentials) could not
actually reach it — a mismatch that previously surfaced as a multi-minute
pool-checkout timeout instead of a fast, legible diagnosis.

## Verification

- **The new preflight module does not exist in the pinned core.** Checked
  the Hex-resolved `phoenix_kit` `2.22.2` in `deps/phoenix_kit` (the version
  in `mix.lock`) — `grep -rl PostgresPreflight deps/phoenix_kit` finds
  nothing. `Code.ensure_loaded?/1` correctly guards this, so `db_check` falls
  back to `:try_connect`, which still exercises the real
  `TestRepo.start_link/0` / migration path in the `else` branch below — this
  is a graceful no-op, not a broken call, and matches this codebase's own
  documented pattern for functionality behind a core version this package
  hasn't shipped yet (`CoreCompat`'s `optional_calls/0`: "a gap degrades
  quietly by design"). Net effect **today**: the PR's own described benefit
  (a fast, specific diagnosis) does not yet fire in this repo; the suite
  still falls through to the same slow "attempt a real connection" path this
  PR's own description says is the problem. Worth confirming intentionally
  with the author whether this landed ahead of the core release it depends
  on, or whether an unpublished core checkout was used to author it — not
  something to "fix" here, since guarding on `Code.ensure_loaded?/1` is
  exactly correct once core does ship it.
- **Found and fixed a real formatting bug** introduced by this PR: the two
  `rescue`/`catch` error messages collapsed a two-line heredoc into one line
  with the second sentence run on with ten literal spaces instead of a
  newline+indent —
  `"...integration tests excluded.          The reason is printed above."` —
  while the sibling message three lines above (`db_check == :not_found`)
  kept the two-line form. Fixed to match (see Fixes below).
- The old `psql -lqt` branch (with its `rescue ErlangError -> :try_connect`
  for a missing `psql` binary) was removed outright rather than kept as a
  fallback tier — acceptable, since the `else` branch (`:try_connect`) is
  exactly the same "just attempt a real connection and see" behavior that
  branch rescued into anyway; no coverage is lost.

## Issues Found & Fixed

### NITPICK: mangled two-line message → one line with a run of spaces
**File:** `test/test_helper.exs`, both `rescue`/`catch` clauses under
`repo_available`

Before:
```elixir
IO.puts("""

  Could not connect to test database — integration tests excluded.          The reason is printed above.
  Error: #{Exception.message(e)}
""")
```

Fixed to a proper two-line message, matching the `db_check == :not_found`
branch's style just above it:
```elixir
IO.puts("""

  Could not connect to test database — integration tests excluded.
  The reason is printed above.
  Error: #{Exception.message(e)}
""")
```
Applied to both the `rescue` and `catch` clauses. Purely cosmetic (output
readability on a connection failure), no behavior change.

## What Was Done Well

- Explains *why* the old check was wrong (unix-socket/shell-user visibility
  vs. the configured role's actual TCP reachability) rather than just
  swapping the mechanism — the kind of context that keeps a future reader
  from reverting it back to `psql -lqt` as a "simplification".

## Verdict

**Approved, with one nitpick fixed** (message formatting). No behavior
change; the underlying diagnostic improvement is currently inert pending a
core release that ships `PhoenixKit.TestSupport.PostgresPreflight` — flagged
above, not something to act on from this side.
