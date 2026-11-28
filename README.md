# PhoenixKitBilling

[![Elixir](https://img.shields.io/badge/Elixir-~%3E_1.18-4B275F)](https://elixir-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Billing module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit). Drop-in payments, subscriptions, invoices, orders, and multi-currency support with Stripe, PayPal, Razorpay, and EveryPay integration.

## Features

- **Orders & invoices** — full order-to-invoice-to-receipt workflow with status tracking and print views
- **Multi-provider payments** — Stripe, PayPal, Razorpay, and EveryPay via a unified Provider behaviour with hosted checkout
- **Internal subscription control** — subscriptions managed in your database, not by providers; automatic renewals and dunning
- **Multi-currency** — currency definitions with exchange rates
- **Billing profiles** — individual and company billing details with address, tax ID, and IBAN validation
- **Transactions & refunds** — complete payment ledger with credit notes and partial refunds
- **Real-time updates** — PubSub events for orders, invoices, transactions, subscriptions, and profiles
- **Admin dashboard** — LiveViews for managing all billing entities, settings, and provider configuration
- **User dashboard** — "My Orders" and "Billing Profiles" pages for end users
- **Print views** — invoice, receipt, credit note, and payment confirmation print layouts
- **Auto-discovery** — implements `PhoenixKit.Module` behaviour; PhoenixKit finds it at startup with zero config

## Installation

Add `phoenix_kit_billing` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_kit_billing, "~> 0.3"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

> **Note:** For development or if not yet published to Hex, you can use:
> ```elixir
> {:phoenix_kit_billing, github: "BeamLabEU/phoenix_kit_billing"}
> ```

PhoenixKit auto-discovers the module at startup — no additional configuration needed.

## Quick Start

1. Add the dependency to `mix.exs`
2. Run `mix deps.get`
3. Enable the module in admin settings (`billing_enabled: true`)
4. Configure at least one payment provider in admin settings
5. Orders and invoices are available at `/admin/billing`

## Usage

### Order-to-Invoice Workflow

```elixir
alias PhoenixKitBilling

# Create an order
{:ok, order} = Billing.create_order(user, %{
  line_items: [%{description: "Widget", quantity: 1, unit_price: Decimal.new("29.99")}],
  currency: "EUR"
})

# Confirm the order
{:ok, order} = Billing.confirm_order(order)

# Generate an invoice from the order
{:ok, invoice} = Billing.create_invoice_from_order(order)

# Send the invoice to the customer
{:ok, invoice} = Billing.send_invoice(invoice)

# Mark as paid (generates receipt automatically)
{:ok, invoice} = Billing.mark_invoice_paid(invoice)
```

### Subscriptions

```elixir
# Create a subscription type (plan)
{:ok, type} = Billing.create_subscription_type(%{
  name: "Pro Monthly",
  slug: "pro-monthly",
  interval: "month",
  price: Decimal.new("19.99"),
  currency: "EUR"
})

# Create a subscription for a user. This charges the card now, for the first period.
{:ok, subscription} =
  Billing.create_subscription(user.uuid, %{
    subscription_type_uuid: type.uuid,
    payment_method_uuid: method.uuid
  })

# A trial takes no card and no money: it is charged when it ends.
{:ok, subscription} =
  Billing.create_subscription(user.uuid, %{subscription_type_uuid: type.uuid, trial_days: 14})
```

A subscription pays in advance, at the price it started on. Editing a plan changes what new subscribers pay; `Billing.apply_plan_price/1` moves the existing ones, and sends them nothing. A plan's price has the tax inside it: with tax enabled, the invoice splits it into net and tax, and the card is charged the same.

A declined first charge leaves no running subscription: `create_subscription/2` returns the reason, and the row stays cancelled with its invoice void. It charges a card, so it cannot be called inside a transaction (`:in_transaction`).

Subscription renewals and failed-payment retries (dunning) are handled automatically by Oban workers.

### Payment Providers

Supported payment providers:

| Provider | Code | Notes |
|----------|------|-------|
| Stripe | `:stripe` | Cards and wallets; signed webhooks |
| PayPal | `:paypal` | PayPal and cards; signed webhooks |
| Razorpay | `:razorpay` | India (UPI, cards); signed webhooks |
| EveryPay | `:everypay` | EveryPay AS gateway (Baltics), API v4; callbacks verified by server-side status re-fetch |

Providers are configured in admin settings. The system uses hosted checkout — users are redirected to the provider's payment page:

```elixir
# Create a checkout session for an invoice
{:ok, session} = Billing.create_checkout_session(invoice, :stripe, %{
  success_url: "https://example.com/success",
  cancel_url: "https://example.com/cancel"
})

# Redirect user to session.url
```

To pay an order with an online payment option, let billing do the whole chain
(open invoice, made payable without an email, checkout session at the option's
provider). A second call returns the same invoice and reuses a recent checkout
URL when its provider, remaining balance, currency, return URLs and customer
email match. All providers charge the invoice's remaining balance.

```elixir
{:ok, %{invoice: invoice, url: url}} =
  Billing.start_order_payment(order, success_url: "https://example.com/orders/1")
```

The payment is confirmed by the provider's webhook, never by the return URL.
The per-order lock is a Postgres session advisory lock, so the repo needs
session pooling (PgBouncer in transaction mode does not keep it on one
connection).

Webhooks are handled automatically at `/webhooks/billing/:provider`.

> **Host setup — raw body reader.** Webhook signature verification needs
> the **raw** request body, so your endpoint must wire
> `PhoenixKitBilling.Plugs.CacheBodyReader` into `Plug.Parsers`:
>
> ```elixir
> plug Plug.Parsers,
>   parsers: [:urlencoded, :multipart, :json],
>   body_reader: {PhoenixKitBilling.Plugs.CacheBodyReader, :read_body, []},
>   json_decoder: Phoenix.json_library()
> ```
>
> `mix phoenix_kit_billing.install` does this for you. **Without it,
> webhooks return `400` with `:no_raw_body`** before processing.

### Refunds

`record_refund/3` books a refund made some other way (a bank transfer).
`refund_at_provider/3` returns the money through the provider that took it,
then books it:

```elixir
# Everything refundable (one provider refund per payment)
{:ok, [%{refund: refund, transaction: tx}]} = Billing.refund_at_provider(invoice, %{}, admin)

# Part of it, with a reason for Stripe
{:ok, _} =
  Billing.refund_at_provider(invoice, %{amount: "10.00", reason: "requested_by_customer",
    description: "Late cancellation"}, admin)
```

Each provider call carries an idempotency key (Stripe's `Idempotency-Key`), and
the ledger row is the refund's own id with the payment it reversed named in its
`provider_data`, so a retry, a double click or the `charge.refunded` webhook that
follows books nothing twice. A refund that takes the invoice to zero voids it
and refunds its order, as `record_refund/3` always has. Each payment gives back
what it took less the refunds that name it; a refund recorded by hand (no charge
id) counts once, through the invoice's `paid_amount`.
`provider_refundable_amount/2` tells what can still be refunded.

A refund the provider reports later as `failed` or `canceled` (Stripe:
`refund.failed` / `charge.refund.updated`) is put back on the invoice: a reversal
row (`provider_data["source"] == "refund_failed"`) brings `paid_amount` back, a
void a refund caused is undone (the invoice is `paid` again only when the ledger
covers its total, else owed; a void made by `void_invoice/3` never is undone), the
admin invoice page shows a warning, and an activity row
(`billing.refund_failed_reversed`) is written. A linked order marked refunded stays
so, on purpose (`refunded` is final for an order) - the warning says it, for the
operator to settle. On a provider with a running total of refunds (Stripe;
EveryPay implements the read-back too but reports no refund failures today)
billing then reads back what the provider has refunded on that payment and books
whatever the ledger lacks, so a replacement refund reported before the failure is
not lost. When that read-back fails, the event is failed so the provider's
redelivery tries it again (the money is put back only once). The failure is found by the refund's id, or, for a
refund the webhook booked without one, by the charge and the amount when exactly
one row fits; otherwise it is logged as unmatched. A failure delivered twice
changes nothing.

The admin refund dialog refunds through the provider when the chosen method is a
provider with a payment on the invoice, and says so. "Already refunded at the
provider - only record it" books the refund without calling the provider (for a
refund made in the provider's dashboard). Give the provider's refund id when you
have it: the row is booked under it, so the provider's webhook and a later failure
of that refund find it. Without one, a provider that reports refunds one at a time
(PayPal, Razorpay) is matched to the booked row by method and amount; on Stripe or
EveryPay the dialog warns that a later refund of that payment made at the provider
may not be booked.

The ledger keeps two decimal places. A currency with more (BHD, KWD, ... -
`decimal_places` above 2 in the currency table) is refused for provider refunds
(`:currency_too_precise`) and for new invoices (a changeset error on `:currency`).
That includes the renewal invoices of an existing subscription in such a currency:
the renewal is then handled like a declined payment (dunning, then cancellation).

### Guest invoices and the payment link

A payer does not need an account. `create_guest_invoice/2` makes an invoice
addressed to an email (the details become its `billing_details`, shown to
admins as "Guest payer — no account" and searchable by that email), and
`invoice_pay_url/1` signs a link to a public payment page,
`/billing/pay/:token`, where the guest sees the invoice and pays through the
providers' hosted checkout:

```elixir
{:ok, invoice} =
  Billing.create_guest_invoice(%{email: "ann@example.com", name: "Ann"}, %{
    total: Decimal.new("15.00"),
    currency: "EUR",
    line_items: [%{"name" => "Yoga class", "quantity" => 1, "unit_price" => "15.00", "total" => "15.00"}],
    metadata: %{"booking_uuid" => booking.uuid}
  })

{:ok, invoice, _email} = Billing.send_invoice(invoice, invoice_url: Billing.invoice_pay_url(invoice))
```

The page is registered by billing's own routes (no host wiring), works for any
invoice, offers payment only while the invoice is payable, and follows the
invoice live, so the payment shows as soon as the webhook lands. The link is
the only credential: send it to the payer only. It is a `Phoenix.Token` signed
with the endpoint's `secret_key_base` (or `config :phoenix_kit_billing,
invoice_link_secret:`) and lasts 180 days (`invoice_link_max_age:`, seconds).
The admin invoice page shows the link of a payable invoice, and a guest's
invoice email links to it. A draft's link opens nothing until the invoice is
sent. `revoke_invoice_pay_links/1` (the admin page's **New link**) stops every
link issued so far for that one invoice - for a link sent to the wrong address -
and the next `invoice_pay_url/1` is a new one; rotating the secret stops them all.

### Voiding an invoice with an open checkout

`void_invoice/3` first closes a checkout session recorded on the invoice that has
not expired (Stripe: the session is expired through the API), so the customer
cannot pay a void invoice through a link they still hold. When the customer
already paid through it, the void is refused with `:checkout_completed`; when the
provider cannot be reached, with `{:checkout_not_closed, reason}`, and
`close_checkout: false` voids anyway (the admin void dialog then offers "Void
anyway"). A provider without
`expire_checkout_session/1`, or one no longer configured, voids as before (logged); a payment that still lands is kept
on the invoice's void trail for a refund. An invoice keeps one session. Billing
asks the provider to close the previous session when replacing it, and to close
the current session when a refund voids the invoice. If closure fails or the
provider has no closure API, a previously issued hosted URL can remain payable
until it expires.

### Testing Stripe locally

1. **Configure test keys** at `/admin/settings/billing/providers` (Stripe
   card): paste your `sk_test_…` / `pk_test_…`, tick **Enabled**, Save. The UI
   writes the `billing_stripe_secret_key` / `billing_stripe_publishable_key` /
   `billing_stripe_webhook_secret` settings; "Active Providers: Stripe" then
   confirms `available?/0` is true.

2. **Forward webhooks to localhost** with the Stripe CLI (no `stripe login`
   needed — pass the key directly):

   ```bash
   brew install stripe/stripe-cli/stripe   # once
   stripe listen --api-key sk_test_… \
     --forward-to http://localhost:4000/phoenix_kit/webhooks/billing/stripe
   ```

   It prints `Your webhook signing secret is whsec_…`. Paste **that** value
   into the **Webhook Secret** field on the providers page and Save — it's what
   the controller verifies against (not the dashboard endpoint's secret).
   Adjust the `/phoenix_kit` prefix to your host's mount.

3. **Fire a test event:**

   ```bash
   stripe trigger checkout.session.completed --api-key sk_test_…
   ```

   Success = a `[200]` in the `stripe listen` output, a
   `phoenix_kit_webhook_events` row with `processed=true`, and a
   `Webhook processed successfully` log line. A `400` with `:no_raw_body`
   means the host hasn't wired `CacheBodyReader` (see above).

### Real-Time Events

Subscribe to billing events in your LiveViews:

```elixir
def mount(_params, _session, socket) do
  PhoenixKitBilling.Events.subscribe_orders()
  {:ok, socket}
end

def handle_info({:order_created, order}, socket) do
  # Update UI
  {:noreply, socket}
end
```

### Durable Events

PubSub is a notification, not a delivery: a listener that is restarting never
hears it. For work that must happen, such as writing off stock or sending an
email, register a handler. Each event is an Oban job, enqueued in the transaction
that changed the record, so it commits with the change or not at all.

| Module | Events | Module callback | Handler function | Host config |
|---|---|---|---|---|
| `PhoenixKitBilling.InvoiceEvents` | `:paid`, `:refunded`, `:voided` | `billing_invoice_event_handlers/0` | `handle_invoice_event/2` | `:invoice_event_handlers` |
| `PhoenixKitBilling.OrderEvents` | `:paid`, `:refunded`, `:cancelled`, `:reinstated` | `billing_order_event_handlers/0` | `handle_order_event/2` | `:order_event_handlers` |

```elixir
# In your PhoenixKit.Module
def billing_order_event_handlers, do: [MyApp.OrderHandler]

defmodule MyApp.OrderHandler do
  @spec handle_order_event(
          :paid | :refunded | :cancelled | :reinstated,
          PhoenixKitBilling.Order.t()
        ) :: :ok | {:error, term()}
  def handle_order_event(:paid, order), do: MyApp.Warehouse.write_off(order)
  def handle_order_event(_event, _order), do: :ok
end
```

Or from the host: `config :phoenix_kit_billing, order_event_handlers: [MyApp.OrderHandler]`.

An invoice handler is registered the same way. A bookings module that confirms a
booking once its invoice is paid, across restarts:

```elixir
# In the bookings PhoenixKit.Module
def billing_invoice_event_handlers, do: [MyBookings.InvoicePaid]

defmodule MyBookings.InvoicePaid do
  # Optional: only for a module that may depend on billing at compile time.
  @behaviour PhoenixKitBilling.InvoiceEventHandler

  @impl true
  def handle_invoice_event(:paid, invoice) do
    # Idempotent: confirming a confirmed booking does nothing.
    MyBookings.confirm_paid(invoice.metadata["booking_uuid"])
  end

  def handle_invoice_event(_event, _invoice), do: :ok
end
```

The `:paid` job is enqueued in the transaction that marks the invoice paid
(whether a webhook, a saved-card charge or an admin's *Mark paid* did it), so it
commits with the payment or not at all. For a live screen, subscribe to the
invoice's own topic as well: `PhoenixKitBilling.Events.subscribe_invoice(uuid)`
delivers `{:invoice_paid, invoice}` and the invoice's other events and
transactions, guest invoices included.

- Delivery is **at-least-once**, so a handler must be idempotent. It is not handed
  the job's `event_uuid`, and (order, event) is not one occurrence: an order
  cancelled, reinstated and cancelled again fires `:cancelled` twice. Make the
  effect idempotent against the order's status instead.
- The handler gets the order **as it is now**, re-read when the job runs.
- `{:error, _}` or a raise retries, up to 20 attempts. A job whose handler is no
  longer registered, or whose order is gone, is cancelled.
- An order's `:refunded` takes a full refund: a partial one leaves the order
  `"paid"` and fires no order event. An order paid through its invoice fires both
  modules' `:paid`.

The jobs run on the `billing` queue, which the module declares through
`oban_queues/0`. `mix phoenix_kit.update` adds it to a host's Oban config, and
`mix phoenix_kit.doctor` reports it when it is missing. Without it the jobs wait
and nothing fails. The daily subscription renewal run is declared the same way,
through `oban_crons/0` (`{"0 6 * * *", PhoenixKitBilling.Workers.SubscriptionRenewalWorker}`),
and written into the host's crontab by the same tasks. A host that copied that
entry into its own Oban config by hand should remove its copy: two entries run the
batch twice (harmless - each subscription is one unique job - but pointless).
Renewals pause while billing is disabled: the batch run does nothing then.

### Reinstating a cancelled order

A cancelled order can be taken back (*Reinstate order* on the admin order page,
under `billing.manage_orders`, with an optional reason):

```elixir
{:ok, order} = PhoenixKitBilling.reinstate_order(order, "Customer called back", actor_uuid: admin.uuid)
{:ok, order} = PhoenixKitBilling.reinstate_order(order, "Refused by the ERP")  # by the system
```

- The order goes back to the status it was cancelled from
  (`metadata["cancelled_from"]`: `draft`, `pending` or `confirmed`; `pending` for
  an order cancelled before that was recorded). `cancelled_at` is cleared and the
  revision moves on, so an external system takes the order again.
- If one of its invoices was paid while it was cancelled, the order is confirmed
  and marked paid in the same transaction. A payment of that invoice running at
  the same time waits for the reinstate, so the order is paid whichever commits
  first. A full refund that commits first voids the invoice, and the reinstate
  then puts the order back where it was cancelled from, unpaid; one that waits
  for the reinstate refunds the order it reinstated.
- The trail is in `metadata["reinstated"]` (`status`, `reason`, `by_uuid`, `at`);
  a reason is also appended to `internal_notes` as `Reinstated <date>: <reason>`.
- Only a `cancelled` order: anything else returns
  `{:error, :order_not_reinstatable}` (`refunded` is final). An order in the trash
  returns `{:error, :order_trashed}` - restore it first.
- Enqueues the durable `:reinstated` order event (and `:paid` after it when a
  paid invoice settled the order), then broadcasts `{:order_reinstated, order}`
  (and `:order_confirmed` / `:order_paid` for the settlement).

### Trash

Orders and draft invoices are not deleted from the admin: they go to a trash
(Orders and Invoices lists have a *Trash* tab) and come back with *Restore*.
Nothing empties it.

```elixir
{:ok, order} =
  PhoenixKitBilling.trash_order(order, actor_uuid: admin.uuid, reason: "Created by mistake")
{:ok, order} = PhoenixKitBilling.restore_order(order)

{:ok, invoice} = PhoenixKitBilling.trash_invoice(invoice, actor_uuid: admin.uuid)
{:ok, invoice} = PhoenixKitBilling.restore_invoice(invoice)

PhoenixKitBilling.list_orders(%{trashed: :only})    # :include for both
```

- A `draft` or `cancelled` order without an open invoice (neither void nor in
  the trash) can be trashed; its status does not change. An invoice can be
  trashed only while it is a `draft` that was never sent - an issued invoice is
  voided - and its number stays used.
- A document in the trash refuses every change with `{:error, :order_trashed}` /
  `{:error, :invoice_trashed}` until it is restored, and no email goes out.
- An invoice cannot be created for, moved onto or restored onto an order in the
  trash (`:order_trashed`). A restore is also refused for a cancelled order
  (`:order_cancelled`; an invoice trashed from it stays in the trash until the
  order is reinstated, and its number stays used) and for an order that has another
  invoice neither void nor in the trash (`:order_has_open_invoices`), so a restore
  never adds a second open invoice. Creating an invoice for a cancelled order is as
  it was before the trash.
- Trashing and restoring leave `updated_at` as it was. They move an order's revision,
  so an external system that holds it (`sync` back to `pending`) takes it again.
- `trash_order/2` takes an optional `:reason` (trimmed, cut like the cancel reason),
  appended to the order's `internal_notes` as `Trashed <date>: <reason>`. It is an
  API option: the admin's Move to trash does not ask for one.
- Restoring a trashed draft invoice puts back its old figures. If the order's
  lines changed meanwhile, the invoice no longer matches them: check it before
  sending.
- A void invoice of a trashed order stays in the invoice lists (it is an issued
  document; only a draft invoice goes to the trash).
- Listings, counts and the dashboard leave the trash out unless asked
  (`trashed: :only | :include`). `get_order/2` and `get_invoice/2` still find it.
- Subscribers of the orders and invoices topics also receive
  `{:order_trashed, order}`, `{:order_restored, order}`, `{:invoice_trashed, invoice}`
  and `{:invoice_restored, invoice}` - and no other event with them.
- Needs migration V8 (`mix phoenix_kit.update`).

### Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `billing_enabled` | boolean | `false` | Enable/disable the billing system |
| `billing_default_currency` | string | `"EUR"` | Default currency for new orders |
| `billing_tax_enabled` | boolean | `false` | Enable tax calculations |
| `billing_company_name` | string | — | Company name on invoices |
| `billing_company_address` | string | — | Company address on invoices |
| `billing_document_logo_file_uuid` | string | — | Media-library file shown at the top of printed documents and in billing emails; unset falls back to the project logo, then the company name |
| `billing_document_footer` | string | — | Text about the company closing every printed document and billing email (at most 1000 characters) |

Provider-specific settings (API keys, webhook secrets) are configured per-provider in the admin panel at `/admin/settings/billing/providers`.

### Invoice Status Workflow

| Status | Description |
|--------|-------------|
| `"draft"` | Invoice created, not yet sent |
| `"sent"` | Invoice sent to customer |
| `"paid"` | Payment received, receipt generated |
| `"overdue"` | Past due date, not yet paid |
| `"void"` | Cancelled / voided |

```
draft → sent → paid
            ↘
           overdue → paid
            ↘
            void
```

### Emails

Billing sends four emails to the customer: `billing_invoice`, `billing_receipt`,
`billing_credit_note` and `billing_payment_confirmation`. They go out through
`phoenix_kit_emails` (`required_modules/0`) and appear in core's email preview
(`/admin/settings/email-sending/preview`) with sample data.

**Language.** A send uses the customer's preferred locale, or the site's content
language for a guest payer or an account without a preference. Billing explicitly
installs that language for its own copy, including when the sender has set a
Gettext backend locale. Dates use core's translated month names and locale-aware
ordering, in both sends and previews. This works from the supported core floor
of 3.5.0.

Each email's built-in copy (`PhoenixKitBilling.EmailDefaults`) has three parts:

| Part | Builds | Line items as |
|------|--------|---------------|
| `subject` | the subject | — |
| `markdown` | the HTML version, inside core's layout | `{{{line_items_table_html}}}` — a ready-made table |
| `text` | the plain-text version | `{{line_items_text}}` — one line per item |

The link to the document online (`{{invoice_url}}`, `{{receipt_url}}`,
`{{credit_note_url}}`, `{{payment_url}}`) is a button. The company's details close
the body; a blank one (an empty VAT number, say) is left out, and so is the
invoice's bank transfer section when there is no IBAN. Both HTML and plain text
omit missing document links, empty bank names and SWIFT codes, and absent company
details. An invoice without a due date omits its payment deadline.

**Overriding.** Put files under `priv/phoenix_kit_templates/<email name>/` in the
host app, as for any email (`subject.txt`, `markdown.md`, `html.html`, `text.txt`,
each optionally per locale: `markdown.et.md`). A part you don't override keeps
billing's default. To keep the line-items table in the HTML version, place
`{{{line_items_table_html}}}` — three braces, because the value is HTML; billing
escapes and styles the table inline — in one of:

- a host `html.html`. Billing's `text` default still builds the plain-text version.
- a host `markdown.md` **and** a host `text.txt` that lists the items with
  `{{line_items_text}}`. A host's `markdown.md` also builds the plain-text version
  when there is no host `text.txt` — it outranks billing's `text` default — and would
  put the table's HTML into it.

A host that overrides only `text.txt` changes the plain-text version, and,
on a core that builds the HTML from a host's text, the HTML version too — then
without the table. `{{{line_items_html}}}` is the older form: bare `<tr>` rows for a
template that wraps them in its own `<table>`.

**Layout group.** Billing emails are sent with `layout: "billing"`, so a host can
give them their own chrome — company details in the footer, say — with
`_layout-billing`, `_header-billing` or `_footer-billing`, each falling back to the
shared `_layout`, `_header` or `_footer`.

An active database template from `phoenix_kit_emails` under the same name still
wins over all of the above.

### Permissions

The module declares permissions via `permission_metadata/0`:

- `"billing"` — access to billing admin dashboard and all sub-pages
- Settings pages require the same `"billing"` permission

Use `Scope.has_module_access?/2` to check permissions in your application.

### CSS Requirements

This module implements `css_sources/0` returning `[:phoenix_kit_billing]`, so PhoenixKit's installer automatically adds the correct `@source` directive to your `app.css` for Tailwind scanning. No manual configuration needed.

### JavaScript and Content-Security-Policy

The module ships one small script, `priv/static/assets/phoenix_kit_billing.js`, declared by `js_sources/0`: PhoenixKit's `:phoenix_kit_js_sources` compiler folds it into `phoenix_kit_modules.js`, which the installer already loads from your root layout. It makes the **Print** button of the printable documents and the **Copy** buttons of the webhook URLs work. If those buttons do nothing, check that the compiler is in your `mix.exs` `compilers:` and that the root layout loads `phoenix_kit_modules.js`.

The module renders no inline event handlers, and its inline `<style>` tags (the printable documents) carry your Content-Security-Policy nonce when PhoenixKit core is one that supports it (`config :phoenix_kit, csp_nonce_assign_key:`); on an older core they render as before. Inline `style="…"` attributes are still used, so keep `style-src-attr 'unsafe-inline'`.

## Architecture

```
lib/
├── phoenix_kit_billing.ex                    # Main module (context + PhoenixKit.Module behaviour)
└── phoenix_kit_billing/
    ├── mix_tasks/
    │   └── phoenix_kit_billing.install.ex    # Install mix task
    ├── events.ex                     # PubSub event broadcasts
    ├── invoice_events.ex             # Durable invoice events for other modules
    ├── order_events.ex               # Durable order events for other modules
    ├── paths.ex                      # Centralized URL path helpers
    ├── supervisor.ex                 # OTP Supervisor
    ├── providers/
    │   ├── provider.ex               # Provider behaviour (9 callbacks)
    │   ├── providers.ex              # Provider registry and routing
    │   ├── stripe.ex                 # Stripe implementation
    │   ├── paypal.ex                 # PayPal implementation
    │   ├── razorpay.ex               # Razorpay implementation
    │   └── everypay.ex               # EveryPay implementation
    ├── schemas/
    │   ├── billing_profile.ex        # User billing information
    │   ├── currency.ex               # Currency definitions
    │   ├── invoice.ex                # Invoice with receipt
    │   ├── number_sequence.ex        # Counter behind order/invoice/receipt/transaction numbers
    │   ├── order.ex                  # Order with line items
    │   ├── payment_method.ex         # Saved payment methods
    │   ├── subscription.ex           # Subscription records
    │   ├── subscription_type.ex      # Subscription plan definitions
    │   ├── transaction.ex            # Payment/refund transactions
    │   └── webhook_event.ex          # Provider webhook log
    ├── workers/
    │   ├── invoice_event_worker.ex          # Oban: durable invoice events
    │   ├── order_event_worker.ex            # Oban: durable order events
    │   ├── subscription_charge.ex           # What signup, renewal and dunning share: one invoice per period
    │   ├── subscription_renewal_worker.ex   # Oban: subscription renewals
    │   └── subscription_dunning_worker.ex   # Oban: failed payment retries
    └── web/                          # Admin LiveViews, controllers, components
```

### Database Tables

| Table | Description |
|-------|-------------|
| `phoenix_kit_billing_profiles` | User billing information (UUIDv7 PK) |
| `phoenix_kit_currencies` | Currency definitions |
| `phoenix_kit_orders` | Orders with line items |
| `phoenix_kit_invoices` | Invoices with receipt data |
| `phoenix_kit_transactions` | Payment/refund transaction ledger |
| `phoenix_kit_subscriptions` | Active subscriptions |
| `phoenix_kit_subscription_types` | Subscription plan definitions |
| `phoenix_kit_payment_methods` | Saved payment methods from providers |
| `phoenix_kit_payment_options` | Available payment options |
| `phoenix_kit_webhook_events` | Provider webhook event log |
| `phoenix_kit_billing_number_sequences` | Counter behind order, invoice, receipt and transaction numbers |

## Development

```bash
mix deps.get       # Install dependencies
mix test           # Run tests
mix format         # Format code
mix credo --strict # Static analysis (strict mode)
mix dialyzer       # Type checking
mix docs           # Generate documentation
mix precommit      # Compile + format + credo + dialyzer
mix quality        # Format + credo + dialyzer
```

### Testing

The module ships its own test harness — a `DataCase`/`LiveCase`, a test
`Endpoint` + `Router`, and core's versioned migrations run via
`PhoenixKit.Migration.ensure_current/2` (no parent app required):

```bash
createdb phoenix_kit_billing_test   # one-time: create the test database
mix test                            # run the suite
```

Use `PhoenixKitBilling.DataCase` for schema/context tests and
`PhoenixKitBilling.LiveCase` for admin LiveView tests.

## Troubleshooting

### Billing not appearing in admin
- Verify `billing_enabled` is `true` in settings
- Ensure the module is listed as a dependency in the parent app's `mix.exs`
- Check that `enabled?/0` is not returning `false` (requires database access)

### Webhooks not processing
- If webhooks return `400` with `:no_raw_body`, the host endpoint is
  missing the raw body reader — wire
  `PhoenixKitBilling.Plugs.CacheBodyReader` into `Plug.Parsers`
  (`body_reader:`) as shown under "Payment Providers" above, or re-run
  `mix phoenix_kit_billing.install`
- Verify webhook secrets are configured in provider settings
- Check that webhook URLs are registered with the provider (e.g., `https://yourdomain.com/webhooks/billing/stripe`)
- Review `phoenix_kit_webhook_events` table for received events

### Subscription renewals or durable events not running
- Ensure Oban is configured in the parent app with the `billing` queue and the renewal cron entry: `mix phoenix_kit.update` adds both (billing declares them through `oban_queues/0` and `oban_crons/0`), and `mix phoenix_kit.doctor` reports what is missing
- Check Oban dashboard for failed jobs

## License

MIT — see [LICENSE](LICENSE) for details.
