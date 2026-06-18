# Contract: NATS Subject Schema

**Plan**: [../plan.md](../plan.md) | The async seam between the Go BFF (publisher) and Python workers (consumers). Every message carries a `trace_id` (UUID) for Langfuse correlation and the security context resolved server-side (never from the client body).

## Subjects

| Subject | Publisher | Consumer | Payload (key fields) |
|---------|-----------|----------|----------------------|
| `ingestion.pdf.<workspace_id>` | BFF (S3 event) | Ingestion worker (Track A) | `{ doc_id, s3_key, workspace_id, user_id, tenant_id, access_level, scope, trace_id }` |
| `ingestion.docx.<workspace_id>` | BFF (S3 event) | Ingestion worker (Track A) | same as above |
| `ingestion.image.<workspace_id>` | BFF (S3 event) | Ingestion worker (Track B, captioning) | same as above |
| `ingestion.crawl.<workspace_id>` | BFF (`/ingest/link`) | Ingestion worker (Track D, Crawl4AI) | `{ doc_id, url, workspace_id, user_id, tenant_id, access_level, scope, trace_id }` |
| `ingestion.audio.<workspace_id>` | BFF (S3 event) | Stub consumer | Returns `501 Not Implemented` (Phase 1 stub, FR-003; Whisper transcription is the Phase 2 implementation) |
| `ingestion.dlq.<workspace_id>` | Ingestion worker | Retry consumer / janitor | Parked chunks (e.g., embed-provider outage) for retry — never re-embedded with a different model (FR-029) |
| `query.agent.<workspace_id>` | BFF (`/query`) | LangGraph worker pool | `{ stream_id, query, workspace_id, user_id, effective_access_level, session_id, intent_hint?, idem_key, trace_id }` |
| `billing.deduct.<workspace_id>` | (Redis outbox drain) | Python billing worker | `{ workspace_id, user_id, cost, operation_type, idem_key, trace_id }` → `INSERT INTO credit_ledger` (idempotent) |
| `billing.grant.<workspace_id>` *(Phase 2)* | BFF (webhook handler, post-verify) | Python billing worker | `{ workspace_id, plan_id, credits, operation_type, payment_id, idem_key, trace_id }` → `INSERT INTO credit_ledger` (positive delta) + `UPDATE workspace_credits` + Redis `INCRBY` (idempotent). See [billing-payments-design.md](../billing-payments-design.md) |
| `notify.<workspace_id>` | Any producer (ingestion / billing / invite / agent-run / admin BFF) | Notification service (Go kernel) | `{ recipient_user_id, category, priority, title, body, payload, workspace_id, trace_id }` → applies prefs, persists row, pushes in-app, and (if enabled) republishes to `notify.email.<ws>` (FR-032–FR-035) |
| `notify.email.<workspace_id>` | Notification service | Python email worker | `{ notification_id, recipient_email, category, title, body, workspace_id, trace_id }` → renders + sends via `EmailSender` port (default: Resend, swappable by env) (FR-035) |
| `notify.email.dlq.<workspace_id>` | Email worker | Retry consumer / janitor | Parked email sends after exhausting provider retries — never silently dropped (FR-035) |

## Rules

- **Security context is authoritative from the publisher.** Workers never read `workspace_id`/`access_level` from untrusted content; they use the fields stamped by the BFF (FR-004, FR-027).
- **Per-subject scaling.** Workers scale per subject (3 pods/subject in Phase 1; KEDA on consumer lag in Phase 2).
- **DLQ semantics.** Embedding-provider outages park the chunk in `ingestion.dlq.<ws>` rather than embedding inconsistently; a retry consumer re-attempts with the original model only (FR-029, research §4).
- **Streaming.** Query workers stream partial results via Redis pub/sub keyed by `stream_id` → Go SSE → browser (see [sse-events.md](./sse-events.md)).
- **Idempotency.** `billing.deduct` consumers rely on `credit_ledger.idem_key UNIQUE`; duplicate drains are no-ops (SC-006).
- **Grant idempotency *(Phase 2)*.** `billing.grant` consumers reuse the same `credit_ledger.idem_key UNIQUE` guarantee plus a `SET NX billing:applied:{idem_key}` guard (research §3); a replayed payment webhook inserts one positive ledger row and performs one Redis `INCRBY`. Grants for recurring invoices are keyed by the invoice ID, so out-of-order/duplicated provider deliveries converge (SC-006).
- **Notification fan-out is centralized.** Producers publish a single `notify.<ws>` event with the resolved `recipient_user_id`; only the notification service knows about preferences, persistence, in-app push, and the email channel. `recipient_user_id` and `workspace_id` are authoritative from the publisher, never from untrusted content (FR-036).
- **Email channel is best-effort and isolated.** In-app delivery is never blocked by email; transient email failures retry and park in `notify.email.dlq.<ws>` (FR-035).

## Contract test obligations

- An `ingestion.audio.*` message yields a clear unsupported result, not a silent drop (FR-003).
- A simulated embed-provider outage routes the chunk to `ingestion.dlq.*`, not into Qdrant (FR-029).
- A duplicated `billing.deduct` with the same `idem_key` inserts one ledger row (SC-006).
- *(Phase 2)* A duplicated `billing.grant` with the same `idem_key` inserts one positive ledger row and applies one Redis `INCRBY` (SC-006).
- A `query.agent.*` run honors `effective_access_level` in its payload pre-filter (SC-001).
- A `notify.<ws>` event whose recipient disabled a category's email channel produces an in-app notification but no `notify.email.<ws>` publish (FR-035).
- A simulated email-provider failure routes the send to `notify.email.dlq.<ws>`, and the in-app notification is delivered regardless (FR-035).
