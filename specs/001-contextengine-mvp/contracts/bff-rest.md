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

## Local agents (US7)

| Method | Path | Purpose | Notes |
|--------|------|---------|-------|
| POST | `/devices/authorize` | Device registration approval (browser) | Issues scoped PAT (user+workspace, 90d) (FR-025) |
| GET | `/devices` / DELETE `/devices/{id}` | List / revoke connected devices | FR-025 |
| POST | `/llm/proxy` | OpenAI-compatible LLM pass-through (proxy sub-mode) | Authenticates PAT, enforces token budget, deducts credits, resolves alias, forwards, traces (FR-026). BYOK devices do not use this. |
| GET | `/agent-runs` / POST `/agent-runs/{id}/cancel` | List / cancel long-horizon runs | Cancel → `cancelling`→`cancelled` (FR-028, SC-009) |

## Contract test obligations

- Access-control: a member never receives a document above clearance or outside workspace via `/documents` or `/query` (SC-001, hard).
- Oversize: `/ingest/presign` with `content_length` > limit → `413 oversize` before any spend.
- Unsupported type: video/audio → `501 unsupported_type` (not silent).
- Blocked credits: exhausted balance → `402` with upgrade path; daily limit → `429`; both with actionable message (SC-010).
- Idempotency: repeated `/query` with same `Idempotency-Key` deducts once (SC-006).
