# Code Review: PR #30 — Currency hygiene: default-currency uniqueness, base-rate invariant, explicit provider currency, schema defaults

**Reviewed:** 2026-09-05
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/30
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** fe5cf0fa7350cf31ed638ce1bd925fc30b817dce
**Status:** Merged

## Summary

Four preparatory changes for per-domain currencies (stage Э0):

1. **Migration chain V2** — `up/1` becomes version-aware; V2 adds a partial unique
   index `phoenix_kit_currencies_default_uidx ON (is_default) WHERE is_default`
   plus `rounding_rule` / `rate_updated_at` columns to the core-created
   `phoenix_kit_currencies`. `down/1` below V2 drops those three objects, never
   the table.
2. **Base-rate invariant** — `set_default_currency/1` renormalizes every
   `exchange_rate` against the new base (raw `update_all`, past the changeset),
   clears the incumbent, then promotes at exactly `1.0`; refuses a nil or
   non-positive base rate with `{:error, :invalid_base_rate}`. Admin copy and the
   rate column were made honest to match.
3. **Providers require an explicit currency** — the six `"EUR"` fallbacks in
   `stripe.ex` / `paypal.ex` are replaced with `Keyword.fetch!/2` or a raised
   `ArgumentError`, read before credential acquisition so the failure is about
   the missing currency rather than an unconfigured provider.
4. **Schema defaults** — `Order.currency` and `Invoice.currency` lose
   `default: "EUR"`; `Transaction.currency` keeps its default until it gets
   validation.

The design is sound and the reasoning in the code comments is unusually good. The
problems below are all *incompleteness*, not wrong direction: a fourth provider
that the sweep missed, a database state the new index cannot survive, a
constraint declared in SQL but not in the changeset, and a DB-backed suite that
never ran.

## Issues Found

### 1. [BUG - HIGH] Razorpay keeps the exact silent-currency fallback the PR removes everywhere else — FIXED
**File:** `lib/phoenix_kit_billing/providers/razorpay.ex` lines 195, 217, 499
**Confidence:** 98/100

The PR's §7.1 invariant is stated in the *behaviour* — `providers/provider.ex` now
documents, for every implementation, that a missing `:currency` raises rather than
defaults. `Razorpay` is a registered implementation of that behaviour
(`Providers.@providers`), and it was left with three `"INR"` fallbacks:

- `create_order/1` (checkout path) — `opts[:currency] || ... || "INR"`
- `create_order_for_recurring/2` (the `charge_payment_method/3` path) —
  `Keyword.get(opts, :currency, "INR")`
- `invoice_to_opts/1` — `invoice[:currency] || ... || "INR"`

So after this PR a caller that omits `:currency` gets a loud `KeyError` on Stripe
and PayPal and a **silent charge in Indian rupees** on Razorpay — worse than the
`"EUR"` default it replaced, because the amount is also reinterpreted in paise.
The behaviour docs the PR wrote are false for a third of the registry.

The new `currency_required_test.exs` enumerated Stripe and PayPal by hand, which
is why nothing caught it — the classic whitelist-vs-registry drift.

**Fixed:** all three sites now `Keyword.fetch!/2` or raise `ArgumentError`, with
the same read-before-credentials ordering and comment style as Stripe/PayPal. The
test file is now driven off `Providers.all_providers/0`: every registered provider
must be classified `:requires_currency` (and is then asserted to raise) or
`{:exempt, reason}`. EveryPay — a *fourth* provider the PR description does not
mention — is classified exempt, correctly: it charges in the currency fixed by the
processing account and sends no currency field at all.

### 2. [BUG - HIGH] The DB-backed suite could not have passed: the schema declares columns only V2 creates, and the harness never runs this module's chain — FIXED
**File:** `test/test_helper.exs`, `lib/phoenix_kit_billing/schemas/currency.ex` lines 52–53
**Confidence:** 100/100

`test_helper.exs` builds the schema from **core's** migrations only
(`PhoenixKit.Migration.ensure_current/2`) — it never applied
`PhoenixKitBilling.Migrations`. V2 is this chain's first shape-changing version,
and the PR added `rounding_rule` / `rate_updated_at` to the `Currency` schema in
the same commit. Every `Currency` insert in the suite therefore raises:

```
** (Postgrex.Error) ERROR 42703 (undefined_column)
   column "rounding_rule" of relation "phoenix_kit_currencies" does not exist
```

On this checkout that is **19 failures**, 13 of them this column, including all
three of the PR's own new `currencies_base_rate_test.exs` tests. The PR reported
"140 tests, 0 failures, 225 excluded" because the entire `DataCase` layer was
excluded in the author's environment; the renormalization was verified by a
standalone `mix run` script instead. The verification was real, but nothing in the
suite was.

**Fixed:** `test_helper.exs` now applies this module's chain on top of core's
baseline, executing `Migrations.up_statements/2` as data (`up/1` needs an
`Ecto.Migrator` runner, and the module deliberately exposes its SQL as data).
`mix test` is 369 tests, 0 failures, 4 skipped.

Worth keeping in view for hosts, though not a defect of this PR: because the
schema now declares columns that only the module chain creates, a host that
upgrades the package without running `PhoenixKitBilling.Migrations.up/1` gets
`undefined_column` on every currency read. That is inherent to shipping a
shape-changing chain version, and is why the release ordering in the moduledoc
matters.

### 3. [BUG - MEDIUM] V2's `CREATE UNIQUE INDEX` aborts on precisely the databases the index exists to fix — FIXED
**File:** `lib/phoenix_kit_billing/migrations.ex` (V2 statement list)
**Confidence:** 92/100

The stated rationale for the index is that a table holding two `is_default` rows
crashes `get_default_currency/0` on every page. That state is reachable today:
`create_currency/1` and `update_currency/2` cast `is_default` straight through the
changeset, and only `set_default_currency/1` demotes the incumbent — core ships no
constraint (checked: V135 creates only `..._code_uidx` and `..._uuid_idx` on this
table).

`CREATE UNIQUE INDEX` against such a table raises a unique violation.
`IF NOT EXISTS` does not help — it guards the index's existence, not the data. So
the migration would abort, and the marker would never stamp, for exactly the hosts
whose currencies table is already broken.

**Fixed:** V2 now emits a repair immediately before the index — demote every
default row but one (lowest `sort_order`, then oldest, then uuid). It is a no-op
on a healthy table (the subselect is NULL, `uuid <> NULL` matches nothing) and a
no-op on re-run, so the chain's idempotence property holds. The existing
"every up statement is guarded" test was extended rather than loosened: the
repair is matched narrowly (`SET is_default = false` … `LIMIT 1`), and any other
unguarded statement still fails. It is the one row-level write this chain makes to
a core-created table, and it only repairs a state no reader can handle.

### 4. [BUG - MEDIUM] The new partial unique index has no matching `unique_constraint/3` — FIXED
**File:** `lib/phoenix_kit_billing/schemas/currency.ex` (changeset)
**Confidence:** 95/100

V2 adds a DB constraint that the changeset does not declare. After migrating,
`create_currency(%{is_default: true, ...})` and `update_currency(c, %{is_default: true})`
stop returning `{:error, changeset}` and start raising `Ecto.ConstraintError` —
an unhandled 500 rather than a form error. The PR did exactly the right thing for
`:code` (`unique_constraint(:code, name: :phoenix_kit_currencies_code_uidx)`,
added in an earlier PR for the same reason) and did not repeat it here.

**Fixed:** `unique_constraint(:is_default, name: :phoenix_kit_currencies_default_uidx)`
added, plus a test that cross-checks the declared constraint name against the name
V2's DDL actually creates, so the two cannot drift.

### 5. [BUG - MEDIUM] Two pre-existing schema tests still assert the removed default — FIXED
**File:** `test/phoenix_kit_billing/schemas/order_test.exs:18`, `test/phoenix_kit_billing/schemas/invoice_test.exs:14`
**Confidence:** 100/100

Both are named "… (currency has a default)" and end in
`refute Map.has_key?(errors, :currency)`. Removing the schema default inverts
them; they fail. The PR added `currency_defaults_test.exs` asserting the *new*
behaviour but left the old assertions of the old behaviour in place.

**Fixed:** both now assert `"can't be blank" in errors.currency`, renamed to match.

### 6. [OBSERVATION] `Keyword.fetch!/2` guards key presence, not a nil value
**File:** `lib/phoenix_kit_billing/providers/stripe.ex:192`, `paypal.ex:116`
**Confidence:** 85/100

`charge_payment_method(pm, amount, currency: nil)` passes `fetch!` — the key is
there — and then dies further in with a `FunctionClauseError` out of
`String.downcase/1` (Stripe) or, for PayPal, only *after* a live token request.
The check is about the caller having thought about currency, and a nil answers
`fetch!` without answering the question.

**Not fixed, deliberately.** The reachable callers pass `invoice.currency` and
`plan.currency`, both `NOT NULL` columns in core's V135 baseline, so nil is not
reachable through this package today. Tightening it would also mean rewriting the
`assert_raise KeyError` assertions this PR just pinned, for a case that cannot
occur — churn without a defect behind it. Worth revisiting if a caller ever builds
an unsaved invoice struct.

### 7. [OBSERVATION] Renormalization can underflow or overflow `numeric(15,6)` at extreme rate ratios
**File:** `lib/phoenix_kit_billing.ex` (`set_default_currency/1`, step 1)
**Confidence:** 80/100

`round(? / ?, 6)` matches the column's scale exactly (core declares
`exchange_rate numeric(15,6)`), so the rounding choice is right. But promoting a
base whose rate is ~2,000,000× another currency's renormalizes that currency to
`0.000000` — after which `Currency.convert/3` divides by zero and
`set_default_currency/1` refuses to promote it back, i.e. the row is stuck. At the
other end, a ratio past 10⁹ overflows the column's 9 integer digits.

**Not fixed.** No pair of real fiat currencies is within three orders of magnitude
of either bound (IRR↔EUR, the widest common pair, lands at ~0.000022), and
guarding it means either widening a core-owned column or adding a validation the
PR argues convincingly against. Recorded so the limit is known before anyone
points this table at crypto.

### 8. [NITPICK] `up(version: 0)` raises `FunctionClauseError`
**File:** `lib/phoenix_kit_billing/migrations.ex` (`up_statements/2` guard `target >= 1`)
**Confidence:** 90/100

`down_statements/2` accepts `0`; `up_statements/2` does not. Not fixed: `up/1`
only ever moves forward, and 0 is `down/1`'s domain — but the asymmetry will read
as an oversight to the next person, so it is on record here rather than in a
guard.

## What Was Done Well

- **The ordering inside `set_default_currency/1` is exactly right**, and it had to
  be: renormalize → clear the incumbent → promote. Clearing before setting is what
  keeps the transaction from tripping the very index V2 adds; promoting through the
  changeset while renormalizing past it is what keeps the base-rate invariant
  enforceable without forbidding the repair operation a host needs. The moduledoc
  explains why the validation is *absent*, which is the hard half to document.
- **`{:error, :invalid_base_rate}` before the transaction**, rather than letting
  Postgres divide by zero — and the test proves it.
- **The migration's version-awareness is genuinely careful**: `min(target, @current_version)`
  clamping, the marker stamped last and stamped with `target`, and the source-text
  test updated in lockstep so `up/1` cannot quietly stop executing what
  `up_statements/2` builds.
- **`down/1` narrowed the destructive-statement test rather than deleting it** —
  `DROP` → `DROP TABLE|TRUNCATE|DELETE`, with the reasoning written down. That is
  the right way to loosen a guard.
- **PayPal's full-refund branch was left currency-free on purpose**, with the rule
  spelled out ("never silently default where it's used", not "require
  everywhere"). Razorpay's refund path turned out to follow the same shape, which
  is why fix #1 left it alone.
- **The i18n was completed in the same commit** — .pot plus all three locales,
  including the new warning string. That is not the usual outcome.

## Verdict

**Approved with fixes.** The design is right and the invariants are the correct
ones to fix at this stage. Five defects were found and fixed post-merge; two of
them — the Razorpay fallback and the never-executed DB suite — shared one root
cause, which is that the sweep was verified against a hand-written list rather
than against the registry and the schema. Both are now enumerated from the source
of truth, so the next provider and the next chain version cannot repeat it.

`mix test`: 369 tests, 0 failures, 4 skipped. `mix precommit` clean.
