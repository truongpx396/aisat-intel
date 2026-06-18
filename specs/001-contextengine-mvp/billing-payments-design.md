# Phase 2 Design: Billing & Payments (Stripe / Polar / PayPal)

**Date**: 2026-06-18 | **Plan**: [plan.md](./plan.md) | **Status**: Design draft (Phase 2 — out of Phase 1 scope per [spec.md](./spec.md) "Out of Scope")

This document specifies the **additive** layer that turns the Phase 1 credit-metering backbone into a monetized, provider-backed billing system. Nothing here changes credit *consumption*: credits remain the single internal unit, decoupled from pricing. A payment provider only converts fiat → credits (one-time top-up) or grants a recurring credit allotment (subscription), then appends a `credit_ledger` row. The consumption hot path (Redis `DECRBY` + outbox + ledger) is untouched.

Layer legend: **K** = kernel (template-level, reusable across products) · **P** = product-specific. All new tables follow the Phase 1 conventions: UUID v7 PKs, `workspace_id NOT NULL` + RLS on tenant-scoped tables, ISO-8601 UTC timestamps, integer money (no floats).

## Design principles

1. **Provider-agnostic core, thin adapters.** A `PaymentProvider` port (Go kernel `billing/`) exposes `CreateCheckout`, `CreatePortalSession`, `VerifyWebhook`, `ParseEvent`, `FetchSubscription`. Stripe, Polar, and PayPal are interchangeable adapters behind it. No product code imports a provider SDK directly.
2. **Money is integer minor units.** All fiat amounts are `BIGINT` minor units (cents) + an ISO-4217 `currency` CHAR(3). Reuses the `cost_usd_micros BIGINT` precedent from [data-model.md](./data-model.md). Never floats.
3. **Webhooks are the source of truth for fulfillment.** Credits are granted on a verified `payment_succeeded` / `invoice_paid` webhook, never optimistically on checkout return. Checkout return only redirects the UI.
4. **Idempotent everywhere.** Provider event IDs dedup in `payment_events`; credit grants reuse the existing `credit_ledger.idem_key UNIQUE` guarantee (SC-006). Replayed webhooks are no-ops.
5. **Signature verification is mandatory (CRITICAL).** Every webhook is HMAC/signature-verified before any parsing or side effect (security ruleset AP4: *Webhook Without Signature Verification = CRITICAL*). Unverified payloads are rejected with `400` and logged, never processed.
6. **Grants flow through the existing outbox.** A purchase publishes the same `billing.deduct`-family path (a new `billing.grant.<ws>` subject) so the durable ledger remains the single audit trail.

## New / extended entities

### `plans` (K) — supersedes the Phase 1 stub
A purchasable product (credit pack or subscription tier).
- `id`, `code` (unique slug, e.g. `pro_monthly`, `pack_10k`), `name`, `description`
- `kind` (`one_time` | `subscription`)
- `price_minor` BIGINT, `currency` CHAR(3) (ISO-4217)
- `credit_allotment` INT (credits granted per purchase / per billing period)
- `billing_interval` (`month` | `year` | NULL for `one_time`)
- `is_active` BOOL, `sort_order` INT, `created_at`, `updated_at`
- Provider price mapping lives in `plan_provider_prices` (below), not here — one plan can map to a Stripe price, a Polar product, and a PayPal plan simultaneously.
- Rules: `credit_allotment` is the *only* coupling between fiat and credits; changing a price never affects already-granted credits.

### `plan_provider_prices` (K)
Maps one logical `plan` to each provider's external price/product/plan ID.
- `id`, `plan_id` → `plans`, `provider` (`stripe` | `polar` | `paypal`), `provider_price_id` TEXT, `created_at`
- `UNIQUE (provider, provider_price_id)` and `UNIQUE (plan_id, provider)`
- Rules: lets the same catalog entry be sold through any provider; the adapter resolves the right `provider_price_id` at checkout.

### `billing_customers` (K)
Links a workspace (the billing entity) to a provider customer record.
- `id`, `workspace_id` → Workspace, `provider` (`stripe` | `polar` | `paypal`), `provider_customer_id` TEXT, `created_at`, `updated_at`
- `UNIQUE (workspace_id, provider)` and `UNIQUE (provider, provider_customer_id)`
- Rules: the workspace is the unit of billing (matches `workspace_credits`). A workspace may have at most one customer record per provider.

### `subscriptions` (K) — supersedes the Phase 1 stub
An active recurring entitlement.
- `id`, `workspace_id` → Workspace, `plan_id` → `plans`, `provider`, `provider_subscription_id` TEXT
- `status` (`trialing` | `active` | `past_due` | `paused` | `canceled` | `incomplete` | `incomplete_expired`)
- `current_period_start`, `current_period_end`, `cancel_at_period_end` BOOL
- `created_at`, `updated_at`, `canceled_at`
- `UNIQUE (provider, provider_subscription_id)`
- Rules: status is driven exclusively by webhooks. Each `invoice_paid` for a subscription grants `plan.credit_allotment` credits via a ledger row keyed by the invoice ID (idempotent renewal grant).

### `payments` (K)
A fiat transaction record (one-time top-up or a subscription invoice), kept for accounting, receipts, refunds, and provider reconciliation.
- `id`, `workspace_id` → Workspace, `provider`, `provider_payment_id` TEXT (PaymentIntent / order / invoice ID)
- `plan_id` → `plans` (nullable for ad-hoc), `kind` (`one_time` | `subscription_invoice`)
- `amount_minor` BIGINT, `currency` CHAR(3), `credits_granted` INT
- `status` (`pending` | `succeeded` | `failed` | `refunded` | `partially_refunded` | `disputed`)
- `receipt_url` TEXT (nullable), `failure_reason` TEXT (nullable)
- `idem_key` TEXT (the key used for the matching `credit_ledger` grant row)
- `created_at`, `updated_at`
- `UNIQUE (provider, provider_payment_id)`
- Rules: a `succeeded` payment maps 1:1 to exactly one `credit_ledger` grant row via `idem_key`. Refunds/chargebacks append a *negative* grant ledger row (see `operation_type` below), never mutate the original.

### `payment_events` (K) — webhook dedup + audit
Raw, verified provider webhook events, for idempotent processing and replay-safety.
- `id`, `provider`, `provider_event_id` TEXT, `event_type` TEXT
- `payload_hash` TEXT (SHA-256 of the raw verified body — body itself not stored long-term; PII/30-day policy from research §9 applies)
- `status` (`received` | `processed` | `ignored` | `failed`)
- `workspace_id` (nullable — resolved from customer mapping after parse), `received_at`, `processed_at`
- `UNIQUE (provider, provider_event_id)`
- Rules: the unique constraint is the replay guard. Insert-on-receive (after signature verification); a duplicate insert short-circuits processing (SC-006-style idempotency for webhooks).

### Extension: `credit_ledger.operation_type`
Phase 1 enumerates only `reconcile` (+ the implicit consumption types). Phase 2 adds the **credit-positive** operation types:
- `grant` (signup / promo), `purchase` (one-time top-up), `subscription_grant` (recurring allotment), `refund` (negative), `chargeback` (negative), `expiry` (negative, if credits expire), `admin_adjustment` (signed).
- **Sign convention (to confirm in implementation):** `credits_used` becomes a signed delta — negative = debit (consumption), positive = credit (grant). The Redis balance is `SUM(delta)`. The column may be renamed `credits_delta` in a Phase 2 migration; document the chosen convention in one place.
- Rules: every grant row carries an `idem_key` (the `payments.idem_key`); the existing `UNIQUE (idem_key)` makes webhook replays and double-clicks no-ops (SC-006).

### Extension: Workspace
- Add `billing_email` (nullable; defaults to owner email) for receipts/invoices.
- No provider IDs on Workspace itself — those live in `billing_customers` to keep multi-provider clean.

## REST contract additions (BFF)

To append to [contracts/bff-rest.md](./contracts/bff-rest.md) under a new **Billing & payments (Phase 2, US4-ext)** section. All authenticated and workspace-scoped unless noted; `workspace_id` resolved server-side from the JWT. Mutating endpoints accept `Idempotency-Key`.

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| GET | `/billing/plans` | List active purchasable plans | Public catalog from `plans` + the caller's currency; no provider IDs leaked |
| POST | `/billing/checkout` | Start a checkout for a plan | Body `{ plan_code, provider? }`; resolves `provider_price_id`, creates/fetches `billing_customers`, returns `{ checkout_url }`. Admin/owner only |
| GET | `/billing/subscription` | Current workspace subscription + entitlement | `{ plan, status, current_period_end, cancel_at_period_end }` or `null` |
| POST | `/billing/subscription/cancel` | Cancel at period end | Sets provider `cancel_at_period_end=true`; status synced via webhook. Owner only |
| GET | `/billing/portal` | Provider-hosted billing/management portal link | Returns `{ portal_url }` (Stripe Billing Portal / Polar / PayPal equivalent). Admin/owner only |
| GET | `/billing/payments` | Workspace payment history | Paginated `?limit=&cursor=`; from `payments`; for the credits-page ledger/receipts |
| POST | `/webhooks/{provider}` | Provider webhook ingress | **Unauthenticated** (verified by signature, not JWT). `{provider}` ∈ `stripe`\|`polar`\|`paypal`. Raw body required for signature verification — must bypass any JSON body-rewrite middleware |

Response/error additions:
- `402 payment_required` (already defined for exhausted balance) now carries an `upgrade_url` pointing at `/billing/checkout` for the recommended plan.
- `POST /billing/checkout` for a non-admin → `403 forbidden`.
- `POST /webhooks/{provider}` with a bad/missing signature → `400 invalid_signature` (logged as a security event), never `2xx`.
- `POST /webhooks/{provider}` for an already-seen `provider_event_id` → `200` no-op (idempotent ack so the provider stops retrying).

## NATS subject additions

To append to [contracts/nats-subjects.md](./contracts/nats-subjects.md):

| Subject | Publisher | Consumer | Payload (key fields) |
|---------|-----------|----------|----------------------|
| `billing.grant.<workspace_id>` | BFF (webhook handler, post-verify) | Python billing worker | `{ workspace_id, plan_id, credits, operation_type, payment_id, idem_key, trace_id }` → `INSERT INTO credit_ledger` (positive delta) + `UPDATE workspace_credits` + Redis `INCRBY` (idempotent) |
| `notify.<workspace_id>` (reuse) | BFF (webhook handler) | Notification service | New categories: `payment_succeeded`, `payment_failed`, `subscription_renewed`, `subscription_canceled` (extend the `notifications.category` enum) |

Rules:
- **Grant idempotency.** `billing.grant` consumers rely on `credit_ledger.idem_key UNIQUE`; a replayed webhook that re-publishes the same `idem_key` inserts one ledger row and performs one Redis `INCRBY` (guarded by `SET NX billing:applied:{idem_key}`, mirroring research §3).
- **Order independence.** A `subscription_grant` for invoice N is keyed by the invoice ID, so out-of-order or duplicated provider deliveries converge to the correct balance.

## Webhook processing flow (per provider)

```
provider → POST /webhooks/{provider}
  1. Read RAW request body (no JSON pre-parse).
  2. VerifyWebhook(signature, secret) — CRITICAL. Fail → 400, log security event, stop.
  3. ParseEvent → { provider_event_id, event_type, object }.
  4. INSERT payment_events (provider, provider_event_id) — ON CONFLICT DO NOTHING.
       conflict → already processed → return 200 (no-op).
  5. Resolve workspace via billing_customers(provider_customer_id).
  6. Map event_type → action:
       payment_succeeded / invoice_paid → upsert payments(succeeded);
            publish billing.grant.<ws> with idem_key = provider_payment_id.
       payment_failed / invoice_payment_failed → payments(failed);
            notify payment_failed (dunning).
       customer.subscription.updated/deleted → upsert subscriptions(status,...).
       charge.refunded / dispute → payments(refunded|disputed);
            publish billing.grant.<ws> with NEGATIVE credits (operation_type=refund|chargeback).
  7. Mark payment_events.status = processed; return 200.
```

Per-provider mapping notes:
- **Stripe**: verify with `Stripe-Signature` (HMAC-SHA256 + timestamp tolerance). Events: `checkout.session.completed`, `invoice.paid`, `invoice.payment_failed`, `customer.subscription.updated|deleted`, `charge.refunded`, `charge.dispute.created`. Use Stripe `idempotency_key` on outbound calls.
- **Polar**: verify with the Polar webhook secret (HMAC). Events: `order.created`, `subscription.active|updated|canceled`, `benefit_grant.*`. Polar is closest to the credit-grant model.
- **PayPal**: verify via PayPal `verify-webhook-signature` API (not a local HMAC — requires a call back to PayPal with the transmission headers + `webhook_id`). Events: `PAYMENT.CAPTURE.COMPLETED`, `BILLING.SUBSCRIPTION.ACTIVATED|CANCELLED`, `PAYMENT.CAPTURE.REFUNDED`.

## Go kernel surface (`billing/`)

```
billing/
  provider.go          # PaymentProvider port (interface)
  providers/
    stripe.go          # adapter
    polar.go           # adapter
    paypal.go          # adapter
  checkout.go          # CreateCheckout / portal orchestration
  webhook.go           # verify → dedup → parse → dispatch
  grants.go            # publish billing.grant, ledger reconciliation helpers
  catalog.go           # plans / plan_provider_prices resolution
```

`PaymentProvider` port (sketch):
```go
type PaymentProvider interface {
    CreateCheckout(ctx, CheckoutInput) (checkoutURL string, err error)
    CreatePortalSession(ctx, customerID string) (portalURL string, err error)
    VerifyWebhook(ctx, rawBody []byte, headers http.Header) (Event, error) // CRITICAL
    FetchSubscription(ctx, providerSubID string) (Subscription, error)
}
```
Selection of the active provider(s) is a kernel `Flags`/config concern (e.g., `billing.providers.enabled = [stripe]`), so adding Polar/PayPal is config + an adapter, not a product change.

## Security checklist (delta from the OWASP ruleset)

- [ ] **AP4** Webhook signature verified before any side effect; raw body preserved; constant-time comparison.
- [ ] **S1/S3** Provider secret keys from environment only; never `NEXT_PUBLIC_`/client-exposed; only publishable keys reach the SPA.
- [ ] **AZ1/AZ6** `/billing/checkout`, `/billing/portal`, cancel are admin/owner-only; re-auth for cancel/downgrade.
- [ ] **AZ4** Webhook handler never trusts `workspace_id`/amount/credits from the client — resolves them from the verified provider object + `billing_customers`.
- [ ] **SC-006** Credit grants idempotent via `credit_ledger.idem_key` + `payment_events` dedup; replays are no-ops.
- [ ] **L2** No card data, no full provider payloads with PII in logs; store `payload_hash`, honor the 30-day raw-retention policy (research §9).
- [ ] **AP6** `/webhooks/*` has a body-size limit; reject oversized payloads.
- [ ] **H8** No CORS on webhook routes; they are server-to-server only.

## What stays unchanged

- Credit **consumption** (Redis hot path, `billing.deduct`, three ceilings, `402`/`429` blocking) — untouched.
- `workspace_credits`, the outbox pattern, and reconciliation — reused as-is; grants are just positive ledger rows.
- The credits UI ([credits.md](../../design-system/aisat-studio/pages/credits.md)) gains a real **Upgrade/Top-up** action wired to `/billing/checkout` and a receipts list from `/billing/payments`; the meter/ledger components are unchanged.

## Open decisions to confirm before implementation

1. **Ledger sign convention**: signed `credits_delta` (recommended) vs. separate debit/credit columns. Pick one and document it once.
2. **Do credits expire?** If yes, add an `expiry` sweep + `expires_at` on grant rows; if no, drop the `expiry` op-type.
3. **Billing entity**: workspace-level only (assumed here) vs. an `organization` above workspace for consolidated billing.
4. **Tax/invoicing**: rely on provider-hosted invoices/tax (Stripe Tax / Polar Merchant-of-Record / PayPal) vs. issuing own invoices. MoR (Polar) materially reduces tax-compliance scope.
5. **Proration & mid-cycle plan changes**: defer to provider proration, or block plan changes to period boundaries.
