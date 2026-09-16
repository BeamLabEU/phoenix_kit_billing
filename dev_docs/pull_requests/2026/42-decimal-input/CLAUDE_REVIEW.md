# Code Review: PR #42 — Migrate free-typed decimal form controls to core's `<.decimal_input>`

**Reviewed:** 2026-09-16
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_billing/pull/42
**Author:** timujinne (Tymofii Shapovalov)
**Head SHA:** 39923db
**Status:** Merged (d1e07c5)

## Summary

Replaces browser `type="number"` controls and hand-rolled `Decimal.parse` /
`Float.parse` calls with core's `<.decimal_input>` and
`PhoenixKit.Utils.Number.parse_decimal/2`, so a comma and a dot both work
unrounded. Sites: billing settings (default tax rate), currencies (exchange
rate), subscription type (price), invoice detail (payment and refund amount),
order form (line-item unit price), plus the context's private `parse_decimal/1`
used by `record_payment/3` and `record_refund/3`. `CoreCompat` gains the two
`parse_decimal` arities and the `DecimalInput` module (plus `Accordion`,
`EmptyState`, `NavTabs`, which were already imported but undeclared).

Two in-PR review rounds already handled the tax-rate range guard lost with the
browser's `min`/`max` and the form reverting on a rejected submit.

Checked and fine:

- Payment/refund amounts lost their `min`/`max` attributes, but the context
  already rejects `<= 0`, an amount above `remaining_amount/1` and a refund
  above `paid_amount` — the browser hint was never the guard.
- Subscription type price lost `min="0"`; `SubscriptionType.changeset/2` has
  `validate_number(:price, greater_than_or_equal_to: 0)`.
- Order line-item price passes `name`, which `decimal_input/1` needs in its
  raw-value clause (`phx-feedback-for={@name}`); `phx-blur`/`phx-value-*` pass
  through `:global`.
- Garbage input: subscription price falls back to the raw string so Ecto's
  cast reports "is invalid"; currency rate is left untouched for the changeset
  to reject. No crash path.

## Findings

### BUG - HIGH: core pin still admitted cores that lack the new API — **fixed**

`<.decimal_input>` and `Number.parse_decimal/2` were both added in core
6a5ef8e0 and first shipped in **phoenix_kit 2.26.0**. `mix.exs` still required
`~> 2.0`, and five LiveViews `import PhoenixKitWeb.Components.Core.DecimalInput`
at compile time. A host locked to any core 2.0–2.25 would resolve this release
without complaint and then fail to compile the dependency
(`module PhoenixKitWeb.Components.Core.DecimalInput is not loaded`). This
repo's own suite couldn't notice: the lock already held 2.26.1.
`core_pin_conformance_test.exs` in fact *required* the pin to admit 2.0.0, so
the correct pin would have failed it.

Fix: pin raised to `~> 2.26`. The conformance test now requires admitting
2.26.x and later 2.x, and rejects 2.0.0 and 2.25.0; its moduledoc and
`AGENTS.md` ("Core compatibility", "Depends on") record the floor and the rule
that adopting a new core API raises it in the same commit.

### IMPROVEMENT - MEDIUM: subscription type form showed two required asterisks — **fixed**

The price field became `<.decimal_input label={gettext("Price") <> " *"} required>`.
`decimal_input/1` (like core `<.input>`) already renders a `*` marker when
`required` is set, so the label read "Price * *". The same was already true of
the Name and Slug `<.input>`s on this form; core's `input.ex` says outright not
to append `" *"` to the label. All three labels dropped the suffix (the msgids
are `"Name"`/`"Slug"`/`"Price"` either way, so the `.pot` is unaffected), and a
test asserts that each label has exactly one asterisk. It fails against the
pre-fix template.

### NITPICK: `parse_tax_rate/1` still goes through a float — not changed

`Settings.parse_tax_rate/1` now parses to a `Decimal` and then calls
`Decimal.to_float/1`, only so it can compare with
`CountryData.get_standard_vat_percent/1` to hide the "suggested rate" hint.
Nothing is persisted or charged from that value, and it matches the old
`Float.parse` behaviour. Switching the comparison to `Decimal` would mean
normalizing core's return type too, which is more change than it's worth here.

### NITPICK: tax-rate label styling differs from sibling fields — not changed

The tax-rate field now uses the component's `label` (`label mb-2 font-semibold`)
while the neighbouring settings fields keep the hand-rolled
`fieldset-legend` label, so this one label looks slightly different. It's
cosmetic and would go away if the settings form moved to core inputs as a whole
(see the component-migration TODO in `AGENTS.md`).

### NITPICK: exchange-rate text is re-rendered in canonical form — not changed

`Currencies` normalizes `"1,5"` → `"1.5"` before `Currency.changeset/2`, so the
form value becomes a `Decimal`, and `decimal_input` shows `1.5` instead of what
was typed. LiveView doesn't overwrite a focused input, so this only shows up
after blur. It's the price of letting the `:decimal` cast see a canonical
string, and the value means the same thing.
