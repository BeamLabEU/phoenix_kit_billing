# Agentic Commerce — Payment Leg (Stripe SPT / Delegated Payments)

**Date:** 2026-06-14
**Author:** Claude (claude-opus-4-8)
**Status:** Research / watch-item — **no build recommended yet**
**Full context & verdict:** `phoenix_kit_ecommerce/dev_docs/agentic_commerce_acp_research.md` (read that first — this doc is the billing-specific slice).

---

## Why this concerns billing

News item — *"Visa plugs its payment network into ChatGPT, letting AI agents shop and pay for users."* The merchant-facing substrate beneath that headline is the **Agentic Commerce Protocol (ACP)** (OpenAI + Stripe), which powers ChatGPT Instant Checkout. ACP has three merchant pieces — product feed, checkout endpoints, **payment** — and the **payment piece is billing's domain**. The feed + checkout-endpoint work lives in ecommerce (or a new bridge plugin); see the companion doc.

**Headline finding for billing:** the payment leg is the **cheapest part of the whole thing** because we already run on Stripe.

---

## The payment primitive: Stripe Shared Payment Token (SPT)

- After the buyer picks a payment method, **Stripe issues a Shared Payment Token scoped to a specific merchant + cart total**. The agent (ChatGPT) passes that token to the merchant via API; the merchant **charges it without ever seeing raw card credentials**.
- SPT is the **first Delegated-Payment-Spec-compatible implementation** in ACP. Non-Stripe PSPs participate via ACP's **Delegated Payments / Shared Token API**.
- For an existing Stripe merchant, Stripe advertises enabling agentic payments in ≈**one line of code**.

Visa Intelligent Commerce is the card-network/authorization+fraud layer above this; Visa cards already flow through our Stripe integration, so **we would not integrate Visa's APIs directly** — SPT-via-Stripe covers it.

---

## Current state (what we already have)

`PhoenixKitBilling` is a strong fit:

- **`Providers.Provider` behaviour (9 callbacks)** — the right seam to add an SPT/delegated-payment path. `lib/phoenix_kit_billing/providers/provider.ex`.
- **Stripe provider** (`lib/phoenix_kit_billing/providers/stripe.ex`) — already does `create_checkout_session`, **`charge_payment_method`** (PaymentIntent off a saved method → `succeeded` + `latest_charge`), `create_refund`, `get_payment_method_details`, and **signed webhook verification** (`verify_webhook_signature` + `handle_webhook_event`). Charging an SPT is conceptually close to the existing `charge_payment_method` path.
- **Webhook idempotency** — duplicate delivery already folds to `:duplicate_event` (`WebhookProcessor`), and the host wires `Plugs.CacheBodyReader` for raw-body signature checks. This is the exact pattern ACP's `complete`-checkout idempotency/signature requirements would model on.
- **Order / invoice / transaction** lifecycle + multi-currency + tax already modeled.

---

## Gap (net-new, small) — if/when we build

1. **SPT charge path.** Add a `Provider` callback (or extend the Stripe provider) to accept a Shared Payment Token and charge it for a given amount/currency, producing a `Transaction` exactly like the saved-method charge path does today. Stripe-first.
2. **Delegated-payment abstraction.** Keep it provider-agnostic at the behaviour level so PayPal/Razorpay/EveryPay can later implement ACP delegated payments without ecommerce/bridge code changing.
3. **Idempotency + signature on the agent-initiated complete.** Reuse the webhook-idempotency + `CacheBodyReader` signature playbook so an agent retrying `complete` can't double-charge.
4. **Refund/capture semantics.** Confirm SPT supports our existing partial-refund/credit-note flow (`create_refund`) — note as an open question against the live spec.

**Out of scope for billing:** the product feed and the ACP checkout REST endpoints — those belong to ecommerce or the proposed `phoenix_kit_acp` bridge plugin.

---

## Decision

**Watch-item, no build now** (beta, US-centric, OpenAI merchant-enrollment gated). When triggered (a host wants to sell via ChatGPT, or ACP exits beta with EU/self-serve onboarding), the billing slice is a **small, well-scoped extension of the existing Stripe `Provider` path** — start the scoping spike from `providers/stripe.ex:charge_payment_method` and the webhook idempotency code.

---

## Open questions (billing-specific) to confirm against the live spec

- SPT lifecycle: scoping (merchant + amount), expiry, single-use vs reusable.
- Partial capture / partial refund / credit-note semantics vs our `create_refund`.
- Exact idempotency + error contract ACP expects on `complete` (align with `:duplicate_event`).
- Whether `stripity_stripe` exposes SPT natively yet, or we call the Stripe REST API via `Req` (as PayPal/Razorpay do).

---

## Sources

See the full source list in `phoenix_kit_ecommerce/dev_docs/agentic_commerce_acp_research.md §8`. Most relevant here:

- Stripe powers Instant Checkout / Shared Payment Token: https://stripe.com/newsroom/news/stripe-openai-instant-checkout
- Agentic Commerce Protocol — Stripe Docs: https://docs.stripe.com/agentic-commerce/acp
- ACP checkout endpoints — Stripe spec: https://docs.stripe.com/agentic-commerce/protocol/specification
- Visa Intelligent Commerce — Visa Developer: https://developer.visa.com/capabilities/visa-intelligent-commerce/overview
