# Quickstart & Validation Guide: AISAT-INTEL MVP (Phase 1)

**Date**: 2026-06-06 | **Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md)

This guide describes how to bring up the system locally and validate the Phase 1 feature end-to-end. It references the [contracts](./contracts/README.md) and [data-model.md](./data-model.md) rather than duplicating them. Implementation details live in `tasks.md` and the code.

## Prerequisites

- Docker + Docker Compose
- Go 1.23, Python 3.12, Node 20+ (for local non-container development)
- Caddy (reverse proxy + automatic TLS / static SPA host) and Casdoor (auth provider) run as compose services; no separate install needed for local dev
- Environment variables (never committed; loaded from env): provider keys `OPENAI_API_KEY`, `COHERE_API_KEY`, optional `ANTHROPIC_API_KEY` / `VOYAGE_API_KEY` (fallbacks) — **consumed by the standalone `llm-gateway` service, not the app tiers**; `LLM_GATEWAY_URL` (default `http://llm-gateway:4000`) + `LLM_GATEWAY_KIND` (`litellm`|`bifrost`); `LANGFUSE_*`, `S3_*`, `TURNSTILE_SECRET`, `JWT_SECRET`, `CASDOOR_*` (endpoint, client id/secret, org/app).

## Bring up the stack

A top-level `Makefile` wraps the common tasks across all three runtimes (preferred entrypoint):

```bash
# from repo root
make up        # docker compose up -d: postgres, redis, qdrant, nats, minio(s3), casdoor, caddy, llm-gateway (:4000)
make migrate   # apply Postgres migrations (RLS policies, partitions) + create Qdrant collections
make dev       # run BFF (:8080), Python workers + MCP (:8000/:8002), and SPA (:5173) together
# ...
make down      # tear down the stack
```

Equivalent explicit commands (what the Makefile targets run under the hood):

```bash
# from repo root
docker compose -f deploy/docker-compose.yml up -d   # postgres, redis, qdrant, nats, minio(s3), casdoor, caddy, llm-gateway(:4000)
# backend-go
cd backend-go && go run ./cmd/api            # BFF on :8080
# backend-python
cd backend-python && uvicorn src.main:app --port 8000   # FastAPI workers + MCP :8002
# frontend
cd frontend && npm install && npm run dev     # SPA on :5173
```

Expected: BFF health check returns 200; Python workers subscribe to NATS subjects; Qdrant has `personal` and `workspace` collections created with payload indexes (`workspace_id`, `user_id`, `access_level`, `hot`, `tags`).

## Seed demo data

A new workspace is seeded (via `OnSignup` hook) with a demo document, a 1000-credit grant, and structured Tier 2 records (employees/projects/metrics) for demonstration.

## Validation scenarios

Each scenario maps to a user story and its success criteria. Run them after bring-up to confirm the feature works end-to-end. These scenarios are automated as a **Playwright** E2E suite (`frontend/tests/e2e/`); the underlying service integration tests provision real Postgres/Redis/NATS/Qdrant via **Testcontainers**, so the same flows are exercised in CI without manual setup.

### Scenario 1 — Ingest → cited answer (US1 + US2, SC-004)
1. Sign up (Turnstile required), then upload a PDF via `POST /ingest/presign` → PUT to S3.
2. Watch `GET /ingest/{jobId}/status` (SSE) progress `received → … → indexed`.
3. Confirm the document appears in `GET /documents` with auto-tags + summary.
4. Ask a question via `POST /query` whose answer lives in the PDF; stream `GET /query/{streamId}`.
5. **Expect**: a cited answer referencing the correct source, within a single short session (< 5 min). `done.credits_deducted` > 0.

### Scenario 2 — Access scoping (US3, SC-001 — hard)
1. Create two members at clearance L1 and L3; ingest a doc at L3.
2. As the L1 member, ask a question whose only answer is the L3 doc.
3. **Expect**: the L3 doc is never retrieved, cited, or reflected; the assistant reports no relevant info. The debug panel `access_filter` shows the doc filtered by clearance.
4. Repeat across two separate workspaces — no cross-workspace content ever returned.

### Scenario 3 — Oversize + unsupported upload (US1, Clarification Q4, FR-003)
1. `POST /ingest/presign` with `content_length` > workspace limit (default 50 MB).
2. **Expect**: `413 oversize` before any ingestion/spend.
3. Attempt a video/audio upload. **Expect**: `501 unsupported_type` — a clear message, not a silent failure.

### Scenario 4 — Prompt-injection refusal (US2, SC-007)
1. Submit a disallowed/obvious-injection input via `POST /query`.
2. **Expect**: a single SSE `error` (`injection_blocked`/`disallowed`), no retrieval, no `done`, zero credit spend; an audit row recorded.
3. Ingest a document containing `"ignore previous instructions…"`, then ask a related question.
4. **Expect**: the assistant treats the delimited content as reference material and does not follow embedded instructions.

### Scenario 5 — Credits: warning, block, idempotency (US4, SC-006/SC-010)
1. Consume AI operations until usage crosses the workspace warning threshold (admin-configurable, default 80%).
2. **Expect**: a warning banner with upgrade CTA (`GET /credits` → `near_limit: true`).
3. Exhaust the balance, attempt another operation. **Expect**: `402 payment_required` with an upgrade path (not silent).
4. Re-submit a query with the same `Idempotency-Key`. **Expect**: charged once (ledger has one row).

### Scenario 6 — Observability (US5, SC-005)
1. Run any query; open the debug panel (`GET /query/{streamId}/debug`).
2. **Expect**: intent, tool called, index tier (HOT/COLD), access-filter summary, BM25/vector/RRF/rerank scores, model used, token cost, credits deducted, and a working `langfuse_trace_url`.

### Scenario 7 — Long-horizon task durability (US7, SC-008/SC-009)
1. With **zero** local agents connected, confirm ingest/query/library/credits/debug all work (SC-008).
2. Register a local agent (`POST /devices/authorize`, proxy sub-mode); start a long-horizon task.
3. Kill the worker mid-run. **Expect**: the run resumes from its checkpoint (janitor re-queue on stale heartbeat).
4. Cancel a running task (`POST /agent-runs/{id}/cancel`). **Expect**: `cancelling → cancelled`.
5. Drive a task toward its `credits_cap`. **Expect**: it halts at the cap with a notification, independent of the daily budget.

### Scenario 8 — Notifications: real-time, scoping, preferences (US8, SC-011/SC-012)
1. Open `GET /notifications/stream` as member A; trigger an event for A (e.g., finish an ingestion). **Expect**: a `notification` event then an updated `unread_count` within seconds (SC-011); the row appears in `GET /notifications`.
2. Mark it read (`POST /notifications/{id}/read`), then `GET /notifications/unread-count`. **Expect**: the count decrements and read state persists.
3. As member B (different recipient/workspace), open the stream and list notifications. **Expect**: A's notification is never visible to B (SC-012, hard).
4. Disable the email channel for a category (`PUT /notifications/preferences`), trigger an event in it. **Expect**: an in-app notification but no `notify.email.<ws>` publish.
5. Simulate an email-provider failure for an enabled category. **Expect**: the send parks in `notify.email.dlq.<ws>` while the in-app notification still arrives.

## Phase 1 eval gate (regression tripwire)

A minimal subset of the eval stack (Promptfoo/DeepEval for prompt assertions, Ragas for retrieval metrics); the full suite is Phase 2.

```bash
cd backend-python && python evals/run.py        # prompt evals (≥20 cases each)
python prompts/retrieval/eval.py                # golden retrieval set (≥30 queries)
```
Gates (FR-030, SC-002/SC-003): `recall@10 ≥ 0.85` (pre-rerank), `recall@5 ≥ 0.80` (post-rerank), `MRR@10 ≥ 0.70`; **access-filter correctness = 100%** is a hard fail (blocks merge) — a query at level N must never return a doc tagged > N.

## CI gates (constitution)

All must pass before merge: lint/format (gofmt+golangci-lint, ruff+black, eslint+prettier), full test suites with ≥80% coverage per runtime, performance/bundle-size checks, security scan, and the Phase 1 eval gate above.
