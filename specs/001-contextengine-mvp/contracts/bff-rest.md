# Contract: Go BFF REST + SSE API

**Plan**: [../plan.md](../plan.md) | All paths are relative to the BFF base URL. All requests authenticated unless noted. `workspace_id` and `Actor` are resolved server-side from the JWT/PAT.

## Conventions

- Error envelope: `{ "error": { "code", "message", "details?" } }`.
- Credit-affecting endpoints accept `Idempotency-Key` and return `X-Credits-Deducted`.
- Pagination: `?limit=&cursor=`; responses include `next_cursor`.

## Auth & identity (kernel)

Browser auth is **OIDC Authorization Code + PKCE** against Casdoor (behind the kernel `Auth` interface); the session is an **opaque reference token** (HttpOnly/Secure/SameSite cookie) looked up in Redis — no claims on the wire, revocable instantly. Full sequence + invariants: [auth-flow.md](./auth-flow.md).

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| POST | `/auth/signup` | Create account + workspace | Turnstile token required (FR-020); fires `OnSignup` (demo doc + 1000 credit grant) |
| GET | `/auth/login` | Begin OIDC login | Stores `state` + PKCE `code_verifier` (Redis); 302 → Casdoor `/authorize` |
| GET | `/auth/callback` | OIDC redirect handler | Validates `state`, exchanges `code` + `code_verifier`, verifies `id_token` (JWKS, `iss`/`aud`/`exp`), creates Redis session + sets opaque session cookie |
| POST | `/auth/logout` | Invalidate session | Deletes Redis session record + clears cookie (immediate revocation) |
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
| POST | `/notes` | Create a note (body + optional `source_links[]`); a bare URL with empty body is accepted and treated as a single source link | Body: `{ body?, source_links?[], access_level?, scope? }`. `access_level` ≤ caller clearance; defaults to caller clearance (FR-004, FR-001) |
| POST | `/notes/{id}/enrich` | Run enrichment for a note (re-runnable) | Publishes `enrich.note.<ws>`; returns a `stream_id`. Checks credit balance at the boundary before publish (FR-001) |
| GET | `/notes/{id}/enrich/{streamId}` (SSE) | Stream enrichment progress + draft | `status` stages: `fetching→distilling→drafting` → `token` deltas → `done`. Draft is not persisted (FR-001) |
| POST | `/notes/{id}` (accept) | Persist the member-accepted note body + citations, then ingest | Sets `enrich_status=accepted`; enters the normal ingestion path (chunk→embed→indexed) |
| POST | `/ingest/note` | Ingest a manual note (no enrichment) | |
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
| POST | `/query` | Ask a question | Returns `{ stream_id }`; publishes `query.agent.<ws>`. Optional `doc_ids[]` **scopes** retrieval to those documents (FR-042) — see below. Optional `clarifies: { id, option_id? }` marks this as the answer to a prior `clarification` (FR-045) — a **new run**, not a resumption; the field exists so eval can measure whether asking helped (SC-017). Moderation gate may short-circuit → `injection_blocked`/`disallowed` before any spend (FR-010, SC-007). Credit-affecting (Idempotency-Key). |
| GET | `/query/{streamId}` (SSE) | Stream tokens + debug trace | Events per [sse-events.md](./sse-events.md); `done` carries `credits_deducted` |
| GET | `/query/{streamId}/debug` | Full debug trace object | Debug panel (FR-021); includes `langfuse_trace_url` |

### Scoped questions & chat attachments (US2, FR-042–FR-044)

**`doc_ids[]` scopes retrieval; it never widens authorization.** With `doc_ids` present, the `retrieve` node searches **only** those documents — the clearance/ownership pre-filter still applies underneath, unchanged. Naming a document the caller cannot read yields **`404 not_found`**, identical to naming one that does not exist, so scoping can never be used to probe for a document's existence (FR-042, SC-001). An empty or omitted `doc_ids` is the normal workspace-wide query. Scoped queries meter and audit identically to unscoped ones.

**A chat attachment is a normal personal-scope ingestion, not a hidden copy.** It reuses `POST /ingest/presign` with `scope='personal'` — same size ceiling (`413 oversize`), same unsupported-type rule (`501` for video/audio), same pipeline, same library visibility, same delete path. Two additions:

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| POST | `/chat/sessions/{id}/attachments` | Register an uploaded file as an attachment of this conversation | Body `{ document_id }` — the document must already exist from `/ingest/presign` + PUT and be **owned by the caller** (non-owner → `404`). Links the document to the session for provenance and returns the ingestion job so the composer can show progress. Does **not** re-upload or copy bytes. |
| GET | `/chat/sessions/{id}/attachments` | List this conversation's attachments | `{ document_id, filename, status, source_type }`; `status` mirrors the ingestion job (`converting`…`indexed`/`failed`). |

**Answering before indexing completes.** Chunk + embed + index is the slow stage; **conversion** is fast. So a small attachment (under a configured token ceiling) is answered **from its converted text in that same turn** while indexing continues in the background; a large one shows in-thread ingestion progress and answers when `indexed`. Either way the document is fully indexed afterwards and behaves like any library document from then on. Without this split, an attachment inherits the asynchronous library budget — SC-004 allows *five minutes* from upload to answer, which is correct for the library and unusable in a conversation.

**Deleting.** An attachment is deleted like any document (`DELETE /documents/{id}`). Deleting the **conversation** does not delete its attachments — they are real library documents the member may still want, and the delete confirmation says so. This is deliberately the opposite of the Mem0 rule (where memory *is* purged with the session), because a memory is a derived artifact of the conversation while an attachment is content the member supplied.

### Chat sessions (US2, FR-009)

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| GET | `/chat/sessions` | List the caller's conversations | Ordered by `last_message_at` **DESC** (never `created_at` — see [data-model.md](../data-model.md)); cursor-paginated (`?cursor=&limit=`, default 30). `?archived=true` returns the archived set; default excludes it. Returns `{ id, title, last_message_at, archived_at }` — never another member's sessions, even at L5. |
| GET | `/chat/sessions/{id}` | One conversation + its turns | Non-owner → `404`, never `403` (existence privacy, same rule as documents — SC-001). |
| PATCH | `/chat/sessions/{id}` | Rename / archive / unarchive | Body `{ title? , archived? }`. A member-set `title` is **sticky** — the system never overwrites it. Title max 200 chars, trimmed; empty string resets to the derived title rather than blanking the row. |
| DELETE | `/chat/sessions/{id}` | Delete conversation **and its memories** | **Purges the Mem0 namespace (`mem0_session_id`) as part of the same operation**, not just the row — otherwise deleted-but-remembered context keeps shaping later answers (FR-009 + the memory invariant in [data-model.md](../data-model.md)). Idempotent. Returns `202` while the purge is in flight; the session reports `deleting` until Mem0 confirms, and a failed purge **retries** rather than reporting success. |

**Title provenance.** `title` is written once after the first turn from the `rewrite` node's normalized query — already computed on the critical path, so a title costs **no extra LLM call and no credit spend** ([agent-graph.md](./agent-graph.md)). If `rewrite` degraded, the truncated raw first message is the fallback. This is a derivation, never a new billable operation: no `operation_type`, no ledger row, nothing for SC-006 to reconcile.

**Archive ≠ delete.** Archiving hides a conversation from the default list and **retains** its memories; deleting destroys both. The two are never presented as the same action, and the delete confirmation must state that memory is purged — a member who believes "deleted" only removed a list entry has been misled about what the system still knows.

## Credits & admin (US4, US6)

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| GET | `/credits` | Workspace balance + warning state | `{ balance, warning_threshold_pct, near_limit: bool }` (FR-016/FR-017) |
| GET | `/admin/usage` | Per-user / per-feature usage + cost (admin) | From `llm_cost_daily` (FR-022) |
| GET | `/admin/policies` / PATCH `/admin/policies/{role}` | Manage agent policies (admin) | FR-022 |

Blocked-operation responses: `402 payment_required` (balance exhausted, with upgrade path, FR-018) and `429 limit_reached` (daily/user limit) — never a silent failure (SC-010).

## Billing & payments (Phase 2, US4-ext)

> Out of Phase 1 scope (see [spec.md](../spec.md) "Out of Scope"); full design in [draft-plan.md — Phase 2 Billing & Payments](../../draft-plan.md#phase-2-billing-and-payments). Additive to the credit backbone — consumption endpoints above are unchanged. All authenticated and workspace-scoped unless noted; mutating endpoints accept `Idempotency-Key`.

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
| POST | `/llm/proxy` | OpenAI-compatible LLM pass-through (proxy sub-mode) | Authenticates PAT, enforces token budget, deducts credits, resolves alias, forwards, traces (FR-026). BYOK devices do not use this. **Transport**: synchronous HTTP streaming pass-through to the standalone LLM gateway (`:4000`, LiteLLM/Bifrost) — `stream:true` relayed verbatim as SSE, flush-per-chunk, context-cancel chained; not gRPC/NATS (research §20, §21). |
| GET | `/agent-runs` / POST `/agent-runs/{id}/cancel` | List / cancel long-horizon runs | Cancel → `cancelling`→`cancelled` (FR-028, SC-009) |

## Approvals — human-in-the-loop (FR-040)

The resolve surface for the reusable human-gate ([approval-ports.md](./approval-ports.md)). All recipient-scoped: a caller sees and resolves only approvals addressed to them (RLS on `approval_request.user_id`).

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| GET | `/approvals` | List the caller's approvals (newest first) | Recipient-scoped via RLS (SC-014). Paginated `?limit=&cursor=`; `?status=pending` and `?kind=` filter. Returns `{ id, kind, subject_ref, prompt, payload, status, created_at, expires_at }[]` |
| GET | `/approvals/{id}` | Approval detail | `404` (not `403`) if the caller is not the approver — existence privacy (SC-014) |
| POST | `/approvals/{id}/resolve` | Record the human decision | Body `{ verdict: "approve"\|"reject"\|"edit", resume_value?, note? }`. **Idempotent** (first decision wins; a replay returns the recorded decision). `404` for a non-approver. On **approve/edit** of a durable-run gate (`long_horizon_action` / `web_search` / `note_edit`, FR-041) → publishes `agent.resume.<ws>` to resume the paused run via `Command(resume)` (a `note_edit` commits the note update + re-index, a `web_search` runs the fetch); on **reject**/expiry the run ends cleanly and the action never runs. Credit-affecting only *after* approve (the gated step's spend), never while pending (FR-040, SC-014) |

The note-enrichment accept (`POST /notes/{id}`, above) is the **enrich-instance of resolve** for `kind='enrich_accept'` — the same gate, surfaced on the note flow rather than the generic inbox.

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
| POST | `/admin/notifications/broadcast` | Send announcement to all workspace members (admin) | Body: `{ title, body, priority? }`; enqueues an **async** fan-out job that delivers per recipient prefs off the request path; returns promptly; audited (FR-037) |
| GET | `/notifications/unsubscribe` | One-click email unsubscribe for a category | Signed token (`?token=`) maps to recipient+category; disables that category's `email` channel; no auth cookie required (FR-035) |
| POST | `/webhooks/email/{provider}` | Email-provider bounce/complaint callback | Verifies provider signature; upserts `email_suppressions`; never trusts unsigned bodies (FR-035) |

## Contract test obligations

- Access-control: a member never receives a document above clearance or outside workspace via `/documents` or `/query` (SC-001, hard).
- Approvals: `GET /approvals` and `POST /approvals/{id}/resolve` never expose or accept another member's approval — a non-approver gets `404` (existence privacy), not the gate (SC-014, hard); a repeated `resolve` with the same decision is a no-op returning the recorded decision (idempotent); approving a paused `long_horizon_action` resumes the run exactly once (no re-spend), and no credit is deducted while the gate is pending (FR-040, SC-014).
- Oversize: `/ingest/presign` with `content_length` > limit → `413 oversize` before any spend.
- Unsupported type: video/audio → `501 unsupported_type` (not silent).
- Blocked credits: exhausted balance → `402` with upgrade path; daily limit → `429`; both with actionable message (SC-010).
- Idempotency: repeated `/query` with same `Idempotency-Key` deducts once (SC-006).
- Notification scoping: a member's `/notifications` list and `/notifications/stream` never include another member's or another workspace's notifications (SC-012, hard).
- Mark-read: `POST /notifications/{id}/read` for a notification the caller does not own returns `404`, not the notification (FR-036).
- Preferences honored: with a category's `email` channel disabled, an event in that category yields an in-app notification but no `notify.email.<ws>` publish (FR-035).
- Idempotent delivery: the same triggering event delivered twice yields one entry in `/notifications` and one unread increment, not two (SC-013, FR-032).
- Async broadcast: `POST /admin/notifications/broadcast` returns promptly (does not block on per-recipient delivery) and is recorded in the audit trail (FR-037).
- Email suppression/unsubscribe: a provider bounce/complaint to `POST /webhooks/email/{provider}` (signature-verified) suppresses further email to that address; `GET /notifications/unsubscribe` with a valid token disables the category's email channel (FR-035).
