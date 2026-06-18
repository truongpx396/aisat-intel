# Contract: Go BFF REST + SSE API

**Plan**: [../plan.md](../plan.md) | All paths are relative to the BFF base URL. All requests authenticated unless noted. `workspace_id` and `Actor` are resolved server-side from the JWT/PAT.

## Conventions

- Error envelope: `{ "error": { "code", "message", "details?" } }`.
- Credit-affecting endpoints accept `Idempotency-Key` and return `X-Credits-Deducted`.
- Pagination: `?limit=&cursor=`; responses include `next_cursor`.

## Auth & identity (kernel)

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| POST | `/auth/signup` | Create account + workspace | Turnstile token required (FR-020); fires `OnSignup` (demo doc + 1000 credit grant) |
| POST | `/auth/login` | Password / magic-link login | Returns session JWT |
| POST | `/auth/logout` | Invalidate session | |
| POST | `/auth/password-reset` | Request/confirm reset | |

## Workspace & members

| Method | Path | Purpose | Maps to |
|--------|------|---------|---------|
| GET | `/workspaces` | List caller's workspaces | US3 |
| POST | `/workspaces` | Create workspace | |
| GET | `/workspaces/{id}` | Workspace settings (incl. `warning_threshold_pct`, `max_upload_bytes`, `byok_enabled`) | FR-003/FR-017/FR-026 |
| PATCH | `/workspaces/{id}` | Update settings (admin) | |
| GET | `/workspaces/{id}/members` | List members + clearance | FR-013 |
| PATCH | `/workspaces/{id}/members/{userId}` | Set role/clearance/limit (admin) | FR-015, FR-022 |
| POST | `/invites` | Invite by email + role/clearance | FR-015 |
| POST | `/invites/{token}/accept` | Accept invite | US3-AS3 |
| DELETE | `/invites/{id}` | Revoke invite | FR-015 |

## Ingestion (US1)

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| POST | `/ingest/presign` | Get presigned S3 PUT URL for a file | Validates `content_length` ≤ `max_upload_bytes` → `413 oversize` (FR-003, Clarification Q4). Body: `{ filename, content_type, content_length, access_level?, scope? }`. `access_level` must be ≤ caller clearance; defaults to caller clearance (FR-004). Unsupported types (video/audio) → `501 unsupported_type` (FR-003). |
| POST | `/ingest/link` | Ingest a web page from a pasted URL | Publishes `ingestion.crawl.<ws>` (FR-001) |
| POST | `/ingest/note` | Ingest a manual note | |
| GET | `/ingest/{jobId}/status` (SSE) | Real-time ingestion progress | `status` events: `received→converting→…→indexed`/`rejected_oversize`/`dlq_parked`/`failed` (FR-003) |

## Library

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| GET | `/documents` | Browse/filter library by tag/access level | RLS + clearance scoped (FR-007) |
| GET | `/documents/{id}` | Document detail (incl. caption for images) | FR-002 |
| DELETE | `/documents/{id}` | Soft-delete document | |

## Query / agent (US2)

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| POST | `/query` | Ask a question | Returns `{ stream_id }`; publishes `query.agent.<ws>`. Moderation gate may short-circuit → `injection_blocked`/`disallowed` before any spend (FR-010, SC-007). Credit-affecting (Idempotency-Key). |
| GET | `/query/{streamId}` (SSE) | Stream tokens + debug trace | Events per [sse-events.md](./sse-events.md); `done` carries `credits_deducted` |
| GET | `/query/{streamId}/debug` | Full debug trace object | Debug panel (FR-021); includes `langfuse_trace_url` |

## Credits & admin (US4, US6)

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| GET | `/credits` | Workspace balance + warning state | `{ balance, warning_threshold_pct, near_limit: bool }` (FR-016/FR-017) |
| GET | `/admin/usage` | Per-user / per-feature usage + cost (admin) | From `llm_cost_daily` (FR-022) |
| GET | `/admin/policies` / PATCH `/admin/policies/{role}` | Manage agent policies (admin) | FR-022 |

Blocked-operation responses: `402 payment_required` (balance exhausted, with upgrade path, FR-018) and `429 limit_reached` (daily/user limit) — never a silent failure (SC-010).

## Billing & payments (Phase 2, US4-ext)

> Out of Phase 1 scope (see [spec.md](../spec.md) "Out of Scope"); full design in [billing-payments-design.md](../billing-payments-design.md). Additive to the credit backbone — consumption endpoints above are unchanged. All authenticated and workspace-scoped unless noted; mutating endpoints accept `Idempotency-Key`.

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| GET | `/billing/plans` | List active purchasable plans | Public catalog from `plans` in caller's currency; no provider IDs leaked |
| POST | `/billing/checkout` | Start checkout for a plan | Body `{ plan_code, provider? }` → `{ checkout_url }`; resolves `provider_price_id`, upserts `billing_customers`. Admin/owner only (AZ1) |
| GET | `/billing/subscription` | Current workspace subscription | `{ plan, status, current_period_end, cancel_at_period_end }` or `null` |
| POST | `/billing/subscription/cancel` | Cancel at period end | Sets provider `cancel_at_period_end=true`; status synced via webhook. Owner only (AZ6 re-auth) |
| GET | `/billing/portal` | Provider-hosted billing portal link | `{ portal_url }`. Admin/owner only |
| GET | `/billing/payments` | Workspace payment/receipt history | Paginated `?limit=&cursor=` from `payments` |
| POST | `/webhooks/{provider}` | Provider webhook ingress | **Unauthenticated**; verified by signature, not JWT. `{provider}` ∈ `stripe`\|`polar`\|`paypal`. Raw body required — bypasses JSON body-rewrite middleware (AP4, CRITICAL) |

Billing responses:
- `402 payment_required` now carries `upgrade_url` → `/billing/checkout` for the recommended plan (FR-018).
- `POST /billing/checkout` by a non-admin → `403 forbidden`.
- `POST /webhooks/{provider}` with a bad/missing signature → `400 invalid_signature` (logged as a security event), never `2xx`.
- `POST /webhooks/{provider}` for an already-seen `provider_event_id` → `200` no-op (idempotent ack so the provider stops retrying).

## Local agents (US7)

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| POST | `/devices/authorize` | Device registration approval (browser) | Issues scoped PAT (user+workspace, 90d) (FR-025) |
| GET | `/devices` / DELETE `/devices/{id}` | List / revoke connected devices | FR-025 |
| POST | `/llm/proxy` | OpenAI-compatible LLM pass-through (proxy sub-mode) | Authenticates PAT, enforces token budget, deducts credits, resolves alias, forwards, traces (FR-026). BYOK devices do not use this. |
| GET | `/agent-runs` / POST `/agent-runs/{id}/cancel` | List / cancel long-horizon runs | Cancel → `cancelling`→`cancelled` (FR-028, SC-009) |

## Notifications (US8)

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| GET | `/notifications` | List caller's notifications (newest first) | Recipient-scoped via RLS (FR-036). Paginated `?limit=&cursor=`; `?unread=true` filters to unread |
| GET | `/notifications/unread-count` | Caller's unread count for the bell badge | `{ unread: number }` (FR-033) |
| POST | `/notifications/{id}/read` | Mark one notification read | Sets `read_at`; idempotent; 404 if not the recipient (FR-033, FR-036) |
| POST | `/notifications/read-all` | Mark all caller notifications read | FR-033 |
| GET | `/notifications/preferences` | List caller's per-category channel prefs | Missing rows return category defaults (FR-035) |
| PUT | `/notifications/preferences` | Upsert caller's prefs | Body: `{ category, in_app, email }[]` (FR-035) |
| GET | `/notifications/stream` (SSE) | Real-time push of new notifications + unread count | Events per [sse-events.md](./sse-events.md): `notification`, `unread_count` (FR-034) |
| POST | `/admin/notifications/broadcast` | Send announcement to all workspace members (admin) | Body: `{ title, body, priority? }`; fans out per recipient prefs; audited (FR-037) |

## Contract test obligations

- Access-control: a member never receives a document above clearance or outside workspace via `/documents` or `/query` (SC-001, hard).
- Oversize: `/ingest/presign` with `content_length` > limit → `413 oversize` before any spend.
- Unsupported type: video/audio → `501 unsupported_type` (not silent).
- Blocked credits: exhausted balance → `402` with upgrade path; daily limit → `429`; both with actionable message (SC-010).
- Idempotency: repeated `/query` with same `Idempotency-Key` deducts once (SC-006).
- Notification scoping: a member's `/notifications` list and `/notifications/stream` never include another member's or another workspace's notifications (SC-012, hard).
- Mark-read: `POST /notifications/{id}/read` for a notification the caller does not own returns `404`, not the notification (FR-036).
- Preferences honored: with a category's `email` channel disabled, an event in that category yields an in-app notification but no `notify.email.<ws>` publish (FR-035).
