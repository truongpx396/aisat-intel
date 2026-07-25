---
description: "Task list for AISAT-INTEL MVP (Phase 1) implementation"
---

# Tasks: AISAT-INTEL MVP — AI-Powered Shared Second Brain (Phase 1)

**Input**: Design documents from `/specs/001-contextengine-mvp/`

**Prerequisites**: [plan.md](./plan.md) (required), [spec.md](./spec.md) (required for user stories), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: Test tasks ARE included. The plan declares TDD NON-NEGOTIABLE (Constitution Principle VI), and every contract in `contracts/` carries explicit "Contract test obligations". Contract/integration tests are written first (Red), must fail, then implementation makes them pass (Green). Integration tests run real backing services via **Testcontainers** (`testcontainers-go` / `testcontainers-python` spin up Postgres/Redis/NATS/Qdrant per run — no shared/mocked infra); critical end-to-end journeys are exercised in the browser via **Playwright**.

**Organization**: Tasks are grouped by user story (US1–US8) to enable independent implementation and testing. Within each story: tests → models → services → endpoints → integration.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story this task belongs to (US1–US8); omitted for Setup / Foundational / Polish
- Exact file paths are included in every task

## Path Conventions (from plan.md)

- **Go BFF/gateway/kernel**: `backend-go/` (`kernel/`, `internal/<feature>/{model,dto,errors,service,infra}`, `migrations/`, `tests/`)
- **Python ML/agent tier**: `backend-python/src/` (`routers/`, `services/`, `mcp_server/`, `schemas/`), `backend-python/tests/`, `backend-python/evals/`
- **React SPA**: `frontend/src/` (`features/<feature>/`, `components/`, `lib/`), `frontend/tests/`
- **Infra**: `deploy/` (`docker-compose.yml`, `Caddyfile`), root `Makefile`

---

## Stage 1: Setup (Shared Infrastructure)

**Purpose**: Three-runtime project skeleton, infra services, and tooling

- [ ] T001 Create the three-runtime directory structure per plan.md: `backend-go/{cmd/api,kernel,internal,migrations,tests}`, `backend-python/{src,tests,evals,prompts}`, `frontend/{src,tests}`, `deploy/`
- [ ] T002 [P] Initialize Go module in `backend-go/go.mod` (Go 1.23) with Gin, GORM, nats.go, go-redis, OpenTelemetry, zerolog, Sentry, and `testcontainers-go` (integration-test deps) dependencies
- [ ] T003 [P] Initialize Python project in `backend-python/pyproject.toml` (Python 3.12) with FastAPI, LangGraph, Mem0, BAML, FastMCP, MarkItDown, Crawl4AI, qdrant-client, `openai` (client pointed at the LLM gateway URL — provider SDKs live in the gateway service, not here), structlog, Langfuse SDK, and `testcontainers` (pytest integration deps)
- [ ] T004 [P] Initialize React SPA in `frontend/package.json` (React 19, Vite, TypeScript 5.x, native EventSource, PostHog) with Vitest (unit/component) and Playwright (cross-browser E2E) test tooling
- [ ] T005 [P] Create `deploy/docker-compose.yml` with postgres, redis, qdrant, nats, minio (S3), casdoor, caddy, and the **llm-gateway** (LiteLLM on `:4000`, config from `deploy/llm-gateway/`) services
- [ ] T006 [P] Create `deploy/Caddyfile` for reverse proxy, automatic TLS, and static SPA serving in front of the BFF
- [ ] T007 [P] Create root `Makefile` with `up`, `down`, `migrate`, `dev`, `build`, `test`, `lint`, `eval` targets across all three runtimes
- [ ] T008 [P] Configure Go linting/formatting in `backend-go/.golangci.yml` including `depguard` to forbid `kernel/` importing `internal/` (Principle I/II)
- [ ] T009 [P] Configure Python linting/formatting (ruff + black) in `backend-python/pyproject.toml`
- [ ] T010 [P] Configure frontend linting/formatting (eslint + prettier) in `frontend/.eslintrc.cjs` and `frontend/.prettierrc`
- [ ] T010a [P] Configure shared test harnesses: Testcontainers bootstrap helpers (`backend-go/tests/containers/` and `backend-python/tests/conftest.py` fixtures spinning up Postgres/Redis/NATS/Qdrant) and a Playwright config + fixtures in `frontend/tests/e2e/playwright.config.ts`

**Checkpoint**: All three runtimes build empty; `make up` brings up infra services.

---

## Stage 2: Foundational (Blocking Prerequisites)

**Purpose**: Kernel interfaces, platform clients, RLS/migrations, shared middleware, and the LLM/MCP/access-control chokepoints that every user story depends on

**⚠️ CRITICAL**: No user story work can begin until this stage is complete

### Go kernel interfaces & platform clients

- [ ] T011 [P] Define kernel interfaces in `backend-go/kernel/auth.go`, `bus.go`, `storage.go`, `mailer.go` (email-send port, default Resend adapter), `meter.go`, `flags.go`, `cache.go`, `actor.go` (consumer-defined, no product imports)
- [ ] T012 [P] Implement Postgres client + GORM setup in `backend-go/internal/platform/postgres/postgres.go`
- [ ] T013 [P] Implement Redis client (logical DB + key-prefix role separation per research §10) in `backend-go/internal/platform/redis/redis.go`
- [ ] T014 [P] Implement NATS client (publish/subscribe helpers) in `backend-go/internal/platform/nats/nats.go`
- [ ] T015 [P] Implement Qdrant client wrapper in `backend-go/internal/platform/qdrant/qdrant.go`
- [ ] T016 [P] Implement OTel tracer + zerolog logger bootstrap in `backend-go/internal/platform/otel/otel.go` and `backend-go/internal/platform/logger/logger.go`
- [ ] T017 [P] Implement Casdoor `Auth` interface adapter in `backend-go/kernel/identity/casdoor/auth.go` (swappable with jwt/workos)

### Database schema, RLS & shared layer

- [ ] T018 Create migration framework + base migration in `backend-go/migrations/0001_init.sql` (UUID v7 helpers, `SET LOCAL app.workspace_id` convention)
- [ ] T019 Create kernel tables migration in `backend-go/migrations/0002_kernel.sql`: `users`, `workspaces`, `workspace_members`, `invites`, `audit_log`, `api_keys`, `plans`, `subscriptions`, `notifications` (recipient `user_id`, `category`, `priority`, `title`, `body`, `payload` JSONB, `idem_key`, `read_at`, `created_at`, index `(user_id, read_at, created_at)`, `UNIQUE(user_id, idem_key)`), `notification_preferences` (`user_id`, `workspace_id`, `category`, `in_app`, `email`, `UNIQUE(user_id, workspace_id, category)`), `email_suppressions` (`email` citext `UNIQUE`, `reason`, `created_at`), `dead_letters` (terminal poison-message store: `workspace_id`, `source_subject`, `dlq_subject`, `payload` JSONB, `dlq_attempts`, `last_error`, `first_failed_at`, `dead_at`), `feature_flags`
- [ ] T020 Create RLS policies migration in `backend-go/migrations/0003_rls.sql` applying `USING (workspace_id = current_setting('app.workspace_id')::uuid)` to every tenant-scoped table (FR-014, SC-001); for `notifications` additionally restrict to the recipient via `USING (workspace_id = current_setting('app.workspace_id')::uuid AND user_id = current_setting('app.user_id')::uuid)` (FR-036, SC-012)
- [ ] T021 [P] Implement shared error envelope `{code,message,details}` in `backend-go/internal/shared/errors/errors.go` and DTO helpers in `backend-go/internal/shared/dto/dto.go` (Principle VIII)
- [ ] T022 [P] Implement Tenant middleware (resolves workspace + Actor from JWT/PAT, runs `SET LOCAL app.workspace_id`, `SET LOCAL app.user_id`, and `SET LOCAL app.clearance` — the Actor already carries clearance) in `backend-go/internal/shared/middleware/tenant.go` (FR-004, FR-027, FR-036). Setting `app.clearance` now gives defense-in-depth on relational document reads and is the request-context seam the Phase 2 second access axis extends with `app.principals` + one RLS predicate additively (no new plumbing later) — see [draft-plan.md — Access model](../draft-plan.md#access-model-decided)
- [ ] T023 [P] Implement Actor/auth + request-id + recovery middleware in `backend-go/internal/shared/middleware/auth.go` and `backend-go/internal/shared/middleware/observability.go`
- [ ] T024 Implement app root wiring (build `appCtx`, call each feature's `SetupModule`) in `backend-go/cmd/api/main.go` and shared router in `backend-go/cmd/api/routes.go`; scaffold `backend-go/cmd/relay/main.go` (SSE streaming role) and `backend-go/cmd/worker/main.go` (background role hosting both **scale-out queue-group consumers** — `notify.<ws>` fan-out + `notify.email.<ws>` email worker, N replicas, idempotent — and **single-owner scheduled jobs** — `*.tick`/`*.refresh` + outbox + DLQ sweep, no in-process timers) sharing the same image (Principle IV, research §14, §15)
- [ ] T024a Implement the generic **DLQ sweeper** (single-owner in `cmd/worker`, triggered by `dlq.sweep.tick`): for each message in every `*.dlq.<ws>` subject, re-publish to its owning work subject with `dlq_attempts+1` under an exponential backoff while `dlq_attempts < MAX_DLQ_ATTEMPTS` (default 5), else write it to `dead_letters` and emit a `dlq.dead.count` metric; never reprocesses payloads itself (re-drive only) in `backend-go/internal/platform/dlq/sweeper.go`, wired in `cmd/worker` (research §18)

### Python tier chokepoints (LLM gateway, MCP server, access filter)

- [ ] T024b [P] Deploy the **standalone LLM gateway service** (LiteLLM on `:4000`) via `deploy/docker-compose.yml` + `deploy/llm-gateway/config.yaml`: map aliases (`fast`/`smart`/`embed`/`rerank`) → provider models, hold provider keys, configure multi-key load-balancing + one-hop fallback + circuit breaker; **disable** its built-in budget/spend and response cache; swappable to Bifrost via `LLM_GATEWAY_KIND` (research §21, §4)
- [ ] T025 [P] Contract test for the LLM gateway-client + service (idempotency, clearance-scoped cache, one-hop fallback via the gateway, embed-no-fallback, PII scrub, OpenAI-wire swappability) in `backend-python/tests/contract/test_llm_gateway.py` per [llm-gateway.md](./contracts/llm-gateway.md)
- [ ] T026 Implement the LLM **gateway-client** wrapper (`LLMRequest`/`LLMResponse`; forwards to the standalone gateway `:4000` via `LLM_GATEWAY_URL`; idempotency, budget gate, clearance-scoped semantic cache, PII scrub via the shared `pii_scrub.py` of T123, cost computation + `billing.deduct` emit, trace + `llm_call_log` write — alias resolution/fallback live in the gateway config of T024b, **not** here) in `backend-python/src/services/llm_gateway.py` (FR-024, FR-029, SC-006, research §21)
- [ ] T027 [P] Implement Qdrant access-control pre-filter helper in `backend-python/src/services/retrieval/filter.py` with **two filter builders** (FR-007, SC-001):
  - `personal_filter(workspace_id, user_id)` → `must = [workspace_id == ctx, user_id == requester_user_id]` (personal collection — owner-only, clearance irrelevant)
  - `workspace_filter(workspace_id, access_level)` → `must = [workspace_id == ctx, access_level <= effective_access_level]` (workspace collection — shared docs)
  - **Deny-by-default guard**: any search invocation reaching Qdrant without a `workspace_id` filter (and, for the workspace collection, an `access_level` bound) MUST raise rather than execute — converting a missing-filter bug into a loud failure instead of a silent cross-tenant leak (SC-001)
  - Both filters must be tested with a member attempting to retrieve another member's personal doc (must return 0 results)
- [ ] T028 Implement FastMCP server bootstrap + per-role `allowed_tools` allowlist dispatch guard in `backend-python/src/mcp_server/server.py` (FR-011, FR-012)
- [ ] T029 [P] Implement FastAPI app entrypoint + NATS subscriber bootstrap in `backend-python/src/main.py`
- [ ] T030 [P] Implement BAML client scaffold + structlog/Langfuse bootstrap in `backend-python/src/baml_client/__init__.py` and `backend-python/src/observability.py`

### Frontend foundation

- [ ] T031 [P] Implement API client (error envelope handling, `Idempotency-Key`) in `frontend/src/lib/api.ts`
- [ ] T032 [P] Implement typed SSE client per [sse-events.md](./contracts/sse-events.md) in `frontend/src/lib/sse.ts`
- [ ] T033 [P] Implement shared design-system primitives + app shell/router in `frontend/src/components/` and `frontend/src/App.tsx` (WCAG 2.1 AA)

### Qdrant collections & seed

- [ ] T034 Create Qdrant collection bootstrap (`personal`, `workspace`) with payload indexes (`workspace_id`, `user_id`, `access_level`, `hot`, `tags`) wired into `make migrate` in `backend-python/src/services/retrieval/bootstrap.py`

**Checkpoint**: Foundation ready — kernel interfaces, RLS, middleware, LLM/MCP/filter chokepoints, and frontend shell exist; user stories can now begin.

---

## Stage 3: User Story 1 - Ingest knowledge into a searchable library (Priority: P1) 🎯 MVP

**Goal**: A member uploads files (PDF/DOCX/MD/image) or pastes a link; the system converts, captions images, auto-tags, summarizes, chunks, embeds, indexes, and streams live progress until the item is browsable in the library.

**Independent Test**: Upload a PDF and paste a URL, watch SSE progress to `indexed`, and confirm both appear in `GET /documents` with auto-tags + summary — no query/team features used.

### Tests for User Story 1 ⚠️ (write first, must fail)

- [ ] T035 [P] [US1] Contract test for `POST /ingest/presign` (oversize → `413`, unsupported video/audio → `501`, access_level ≤ caller clearance) in `backend-go/tests/contract/ingest_presign_test.go` per [bff-rest.md](./contracts/bff-rest.md)
- [ ] T036 [P] [US1] Contract test for `POST /notes`, `POST /notes/{id}/enrich`, `GET /notes/{id}/enrich/{streamId}` SSE stages, note accept (`POST /notes/{id}`), and `GET /ingest/{jobId}/status` in `backend-go/tests/contract/ingest_test.go` per [bff-rest.md](./contracts/bff-rest.md)
- [ ] T037 [P] [US1] Contract test for ingestion + enrich NATS subjects (`ingestion.pdf/docx/image`, `enrich.note` → SSRF-guarded crawl → `ingestion.crawl` internal step, `audio`→501 stub, embed-outage→`ingestion.dlq`) in `backend-python/tests/contract/test_ingestion_subjects.py` per [nats-subjects.md](./contracts/nats-subjects.md)
- [ ] T037a [P] [US1] Contract test for `ingestion.dlq` drain via `dlq.sweep.tick` — a parked chunk under the cap is re-driven to the embed step with the original model only and re-embeds idempotently (no duplicate Qdrant point); a chunk reaching `MAX_DLQ_ATTEMPTS` lands in `dead_letters` with a `dlq.dead.count` emit and is not re-driven again in `backend-go/tests/contract/dlq_ingestion_test.go` per [nats-subjects.md](./contracts/nats-subjects.md) (research §18, FR-029)
- [ ] T038 [P] [US1] Integration test for ingestion pipeline (PDF → converting → metadata → chunking → embedding → indexed) in `backend-python/tests/integration/test_ingestion_pipeline.py`
- [ ] T039 [P] [US1] Contract test for `GET /documents` and `GET /documents/{id}` (clearance + RLS scoped, image caption present) in `backend-go/tests/contract/documents_test.go`

### Implementation for User Story 1

- [ ] T040 [US1] Create `Document` partitioned table migration (`source_type` incl. `note`, note columns `body`/`source_links[]`/`citations[]`/`enrich_status`, `tags[]`, `summary`, `data_type`, `access_level`, `scope`, server-stamped security fields, partition by `created_at`) in `backend-go/migrations/0010_documents.sql` (FR-004, FR-001)
- [ ] T041 [P] [US1] Implement `Document` model in `backend-go/internal/ingest/model/document.go`
- [ ] T042 [P] [US1] Implement ingest DTOs + errors (presign request/response, oversize, unsupported) in `backend-go/internal/ingest/dto/dto.go` and `backend-go/internal/ingest/errors/errors.go`
- [ ] T043 [US1] Implement presign service (validate `content_length ≤ max_upload_bytes` → 413, reject video/audio → 501, stamp security fields, default access_level to caller clearance, issue S3 presigned PUT) in `backend-go/internal/ingest/service/presign.go` (FR-003, FR-004)
- [ ] T044 [US1] Implement ingestion + enrich orchestration service (S3 event → publish `ingestion.<mime>.<ws>`; `POST /notes/{id}/enrich` → publish `enrich.note.<ws>`; note accept → normal ingestion) in `backend-go/internal/ingest/service/orchestrate.go` (FR-001)
- [ ] T045 [US1] Implement document repository (RLS-scoped list/get/soft-delete) in `backend-go/internal/ingest/infra/repo/document_repo.go`
- [ ] T046 [US1] Implement ingest + notes HTTP transport (`/ingest/presign`, `/notes`, `/notes/{id}/enrich`, `/notes/{id}/enrich/{streamId}` SSE, `/notes/{id}` accept, `/ingest/note`, `/ingest/{jobId}/status` SSE, `/documents`, `/documents/{id}`, DELETE) + `SetupModule` in `backend-go/internal/ingest/infra/transport/http/handler.go` and `backend-go/internal/ingest/module.go`
- [ ] T047 [P] [US1] Implement ingestion schemas in `backend-python/src/schemas/ingest.py`
- [ ] T048 [US1] Implement ingestion pipeline orchestrator + NATS consumers per MIME, with status emission via Redis pub/sub in `backend-python/src/services/ingestion/pipeline.py` and `backend-python/src/routers/ingest.py`
- [ ] T049 [P] [US1] Implement MarkItDown converter (PDF/DOCX/MD) in `backend-python/src/services/ingestion/markitdown.py` (FR-001)
- [ ] T050 [P] [US1] Implement image captioner via LLM gateway `fast` alias in `backend-python/src/services/ingestion/captioner.py` (FR-002)
- [ ] T051 [P] [US1] Implement shared `web_distill(urls, intent)` capability — SSRF-guarded fetch (https-only; reject private/loopback/link-local/reserved IPs after resolving all A/AAAA; `redirect:error`; bounded size+timeout) → Crawl4AI → distill-against-intent — in `backend-python/src/services/ingestion/web_distill.py` (FR-001). Reused by Phase-2 `web_search`.
- [ ] T051a [P] [US1] Implement note-enrich worker (consumes `enrich.note.<ws>`: calls `web_distill(source_links, intent=body)`, LLM-synthesizes a draft, streams `fetching→distilling→drafting→token→done` via Redis pub/sub; draft not persisted) in `backend-python/src/services/ingestion/enrich.py` (FR-001)
- [ ] T052 [P] [US1] Implement `ingestion.audio` 501 stub consumer in `backend-python/src/services/ingestion/audio_stub.py` (FR-003)
- [ ] T053 [P] [US1] Implement BAML metadata extractor (advisory tags/data_type/summary/suggested_sensitivity — advisory only) in `backend-python/src/services/ingestion/tagger.py` (FR-002, FR-005)
- [ ] T054 [US1] Implement **structure-aware** parent/child chunker in `backend-python/src/services/ingestion/chunker.py` (research §16): split on document structure (markdown headings / paragraph / sentence boundaries / table rows / code fences, recursive token-splitter fallback for unstructured text) — never mid-sentence — into a parent/child "small-to-big" scheme (child 200 / parent 1000 tokens, `parent_doc_id` link); child is the embedded/searched unit, parent is sent to the LLM
- [ ] T054a [P] [US1] Implement flag-gated **contextual-retrieval** prefix in the chunker (research §16): when kernel flag `chunking.contextual_prefix` is on (default on for text docs), prepend each child with a short situating line generated via the `fast` alias, computing the per-document summary **once** and reusing it across that doc's chunks to bound cost; prefix is embedded with the child but recorded as non-citable (not a citation span); enabling it in CI is gated on the `evals/run.py` recall/MRR/citation gate (T125)
- [ ] T055 [US1] Implement embed + Qdrant upsert with full payload (incl. `access_level`, `hot`); embed-provider outage → `ingestion.dlq.<ws>` carrying `dlq_attempts`/`first_failed_at` (no model substitution); a sweeper re-drive re-embeds the **same chunk id** idempotently (upsert, not duplicate point) in `backend-python/src/services/ingestion/embed_index.py` (FR-029, research §18)
- [ ] T056 [P] [US1] Implement upload + library UI (drag-drop, presign PUT, live SSE progress, document list with tags/summary, image caption view) in `frontend/src/features/upload/` and `frontend/src/features/library/`

**Checkpoint**: US1 fully functional — ingest PDF/DOCX/MD/image/link, live progress, browsable library. MVP-demoable on its own.

---

## Stage 4: User Story 2 - Ask questions and get access-scoped, cited answers (Priority: P1)

**Goal**: A member asks a natural-language question; the LangGraph agent moderates, rewrites, retrieves (hybrid + rerank) within clearance scope, expands chunks, injects memory, generates a cited answer, and streams it — never surfacing content above clearance or following injected instructions.

**Independent Test**: After ingesting a few docs, ask a question whose answer lives in one; confirm the response cites the correct source and never references docs above clearance; a follow-up uses session context.

### Tests for User Story 2 ⚠️ (write first, must fail)

- [ ] T057 [P] [US2] Contract test for `POST /query` (returns `stream_id`, moderation short-circuit → `injection_blocked`/`disallowed` before spend, idempotency) in `backend-go/tests/contract/query_test.go` per [bff-rest.md](./contracts/bff-rest.md)
- [ ] T058 [P] [US2] Contract test for query SSE taxonomy + `DebugTrace` shape in `backend-go/tests/contract/query_sse_test.go` per [sse-events.md](./contracts/sse-events.md)
- [ ] T059 [P] [US2] Contract test for MCP knowledge tools — `search_workspace_knowledge` never returns `access_level > effective_access_level`; structured tools reject raw SQL (typed filters only) in `backend-python/tests/contract/test_mcp_tools.py` per [mcp-tools.md](./contracts/mcp-tools.md)
- [ ] T060 [P] [US2] Integration test for LangGraph graph happy path (moderate→rewrite→retrieve→rerank→memory→generate→cite) in `backend-python/tests/integration/test_agent_graph.py`
- [ ] T060a [P] [US2] Integration test for empty/unanswerable query (no authorized documents relevant → grounded "no relevant information" refusal, no fabrication, no cross-clearance leak) in `backend-python/tests/integration/test_unanswerable_query.py` (FR-006, FR-007, SC-001)
- [ ] T061 [P] [US2] Integration test for prompt-injection defenses (delimited retrieved doc with "ignore previous instructions" is treated as data; injected tool call does not escalate) in `backend-python/tests/integration/test_injection_defense.py` (FR-010, FR-011, SC-007)
- [ ] T061a [P] [US2] Integration test for memory clearance scoping — write a memory from an L4 answer (with a unique sentinel fact), demote the member to L2, then ask a question that would surface it and assert the L4-derived memory is **not** injected at Node 5 and the sentinel never appears in the L2 answer (FR-009, SC-001, research §13)
- [ ] T062 [P] [US2] Integration test for structured-data Tier 2 answer via fixed `query_employees/projects/metrics` tools in `backend-python/tests/integration/test_structured_query.py` (FR-008)

### Implementation for User Story 2

- [ ] T063 [US2] Create `Chat Session` table (`mem0_session_id`, hash-partitioned by `user_id`) and structured Tier 2 tables (`employees`, `projects`, `metrics`) migration in `backend-go/migrations/0011_query_structured.sql` (FR-009, FR-008)
- [ ] T064 [P] [US2] Implement query schemas (`query.agent` payload, debug trace) in `backend-python/src/schemas/query.py` and `backend-python/src/schemas/agent.py`
- [ ] T065 [P] [US2] Implement hybrid retrieval in `backend-python/src/services/retrieval/hybrid.py` (FR-007, SC-001): run **two parallel Qdrant searches** — `personal` collection with `personal_filter(workspace_id, requester_user_id)` and `workspace` collection with `workspace_filter(workspace_id, user_access_level)` — then RRF-interleave both result sets before reranking. The merged candidate set must never contain chunks from another user's personal docs.
- [ ] T066 [P] [US2] Implement reranker via LLM gateway `rerank` alias + hot/cold tier routing in `backend-python/src/services/retrieval/reranker.py` and `backend-python/src/services/retrieval/hot_cold.py`
- [ ] T067 [P] [US2] Implement child→parent chunk expansion in `backend-python/src/services/retrieval/expand.py`
- [ ] T068 [P] [US2] Implement Mem0 per-user memory injection in `backend-python/src/services/agent/memory.py` (FR-009, SC-001, research §13): on **write**, stamp each memory with `workspace_id`, `user_id`, and `access_level` = the highest `access_level` among contributing chunks/answer; on **read** (Node 5), inject only memories satisfying `workspace_id == ctx AND user_id == ctx AND access_level <= effective_access_level` against the requester's **current** clearance — a memory above current clearance (e.g., post L4→L2 demotion) is never injected
- [ ] T069 [P] [US2] Implement semantic + exact answer cache keyed by `workspace+user+access_level+model+query` with `cacheable_scope` in `backend-python/src/services/agent/cache.py` (FR-007, SC-001, research §2)
- [ ] T070 [US2] Implement MCP knowledge tools (`search_personal_knowledge`, `search_workspace_knowledge`, `get_document_by_id`, `list_documents`) in `backend-python/src/mcp_server/tools/knowledge.py` (FR-006, FR-007)
- [ ] T071 [P] [US2] Implement MCP structured tools (`query_employees`, `query_projects`, `query_metrics`, parameterized SQL only) in `backend-python/src/mcp_server/tools/structured.py` (FR-008)
- [ ] T072 [P] [US2] Implement MCP utility tools (`get_current_datetime`) in `backend-python/src/mcp_server/tools/utility.py` (FR-011, FR-012). No agent-callable crawl tool in Phase 1; the Phase-2 `web_search` tool (user+admin, per-search HITL) is registered additively later.
- [ ] T073 [US2] Implement LangGraph 7-node agent graph (Node 0 moderation gate → intent router → rewrite → retrieve → rerank/expand → memory → generate+cite), treating retrieved content as delimited untrusted data in `backend-python/src/services/agent/graph.py` (FR-010, FR-011, SC-007)
- [ ] T074 [P] [US2] Implement response-format + prompt assets in `backend-python/prompts/{query_rewrite,response_format,retrieval,metadata_extract,image_caption}/`
- [ ] T075 [US2] Implement query router consuming `query.agent.<ws>`, running the graph, streaming partial results via Redis pub/sub keyed by `stream_id` in `backend-python/src/routers/query.py`
- [ ] T076 [US2] Implement Go query service + SSE relay (`POST /query` publishes `query.agent.<ws>`, moderation short-circuit, `GET /query/{streamId}` SSE relay, `GET /query/{streamId}/debug`) + `SetupModule` in `backend-go/internal/query/service/query.go`, `backend-go/internal/query/infra/transport/http/handler.go`, `backend-go/internal/query/module.go`
- [ ] T077 [P] [US2] Implement chat UI (multi-turn conversation, streaming tokens, inline citations, suggested follow-up chips) in `frontend/src/features/chat/` (FR-031)
- [ ] T077a [P] [US2] Implement follow-up question generator (Node 7, post-generate) in `backend-python/src/services/agent/suggestions.py`; emits `suggestions` SSE event with 2–3 clearance-scoped question strings after `done`; suppressed on moderation block or zero-source answer (FR-031)
- [ ] T077b [P] [US2] Contract test for `suggestions` SSE event — correct shape `{ questions: string[] }`, exactly 2–3 items, suppressed when `source_count == 0` or answer was refused, in `backend-go/tests/contract/query_sse_suggestions_test.go` (FR-031)

**Checkpoint**: US1 + US2 form the MVP loop — ingest → ask → cited, access-scoped, injection-resistant answer with session memory.

---

## Stage 5: User Story 3 - Access-controlled team workspace (Priority: P2)

**Goal**: Members share a workspace combining personal + team knowledge; clearance-scoped retrieval/browsing; owners/admins invite, assign role/clearance, and revoke.

**Independent Test**: Two members at different clearance levels see only permitted docs in library and query results; cross-workspace visibility is impossible.

### Tests for User Story 3 ⚠️ (write first, must fail)

- [ ] T078 [P] [US3] Contract test for `/workspaces`, `/workspaces/{id}` (settings incl. `warning_threshold_pct`/`max_upload_bytes`/`byok_enabled`), `/workspaces/{id}/members` in `backend-go/tests/contract/workspace_test.go`
- [ ] T079 [P] [US3] Contract test for `/invites`, `/invites/{token}/accept`, `DELETE /invites/{id}` (role+clearance assignment, revoke) in `backend-go/tests/contract/invite_test.go` (FR-015)
- [ ] T080 [P] [US3] Integration test for cross-workspace isolation + clearance scoping (L1 vs L3 member, two workspaces) in `backend-go/tests/integration/access_isolation_test.go` (FR-007, FR-014, SC-001)

### Implementation for User Story 3

- [ ] T081 [P] [US3] Implement `Workspace` + `WorkspaceMember` models in `backend-go/kernel/tenancy/model.go`
- [ ] T082 [P] [US3] Implement `Invite` model in `backend-go/kernel/identity/invite.go`
- [ ] T083 [US3] Implement workspace service (create, get/update settings, list/patch members + role/clearance/limit, enforce uploader cannot exceed own clearance) in `backend-go/internal/workspace/service/workspace.go` (FR-004, FR-013, FR-015)
- [ ] T084 [US3] Implement invite service (invite by email, accept assigns role+clearance, revoke) in `backend-go/internal/invite/service/invite.go` (FR-015)
- [ ] T085 [P] [US3] Implement workspace + invite repositories (RLS-scoped) in `backend-go/internal/workspace/infra/repo/workspace_repo.go` and `backend-go/internal/invite/infra/repo/invite_repo.go`
- [ ] T086 [US3] Implement workspace + invite HTTP transports + `SetupModule` in `backend-go/internal/workspace/infra/transport/http/handler.go`, `backend-go/internal/invite/infra/transport/http/handler.go`, and their `module.go`
- [ ] T087 [US3] Implement `OnSignup` hook (create workspace + seed demo doc + structured records + 1000-credit grant) in `backend-go/kernel/identity/onsignup.go`
- [ ] T088 [P] [US3] Implement workspace/member management UI (members list + clearance, invite form, revoke) in `frontend/src/features/workspace/`

**Checkpoint**: US1–US3 work independently; multi-tenant access control is enforced and verifiable.

---

## Stage 6: User Story 4 - Credit-based usage metering and budgets (Priority: P2)

**Goal**: Every AI operation deducts from a shared workspace balance in real time with three independent ceilings (workspace balance, per-user daily, per-call output cap); near-limit warning, graceful block, exactly-once charging.

**Independent Test**: Run AI ops, confirm balance decrements by documented amounts, warning appears at threshold, exhaustion blocks with a clear message; a double-submit charges once.

### Tests for User Story 4 ⚠️ (write first, must fail)

- [ ] T089 [P] [US4] Contract test for `GET /credits` (`balance`, `warning_threshold_pct`, `near_limit`), `402 payment_required`, `429 limit_reached` in `backend-go/tests/contract/credits_test.go` per [bff-rest.md](./contracts/bff-rest.md)
- [ ] T090 [P] [US4] Contract test for `billing.deduct` idempotency (duplicate `idem_key` → exactly one ledger row written by the **Go** billing worker; Python never writes the ledger) in `backend-go/tests/contract/billing_deduct_test.go` per [nats-subjects.md](./contracts/nats-subjects.md) (SC-006)
- [ ] T091 [P] [US4] Integration test for credit lifecycle (deduct → warn at threshold → block at exhaustion → reconcile Redis↔ledger) in `backend-go/tests/integration/credits_lifecycle_test.go` (FR-016–FR-019, SC-006, SC-010)

### Implementation for User Story 4

- [ ] T092 [US4] Create `workspace_credits` + `credit_ledger` migration (append-only, partitioned, `UNIQUE (idem_key) WHERE idem_key IS NOT NULL`) and `token_usage_daily` in `backend-go/migrations/0012_credits.sql` (FR-019, SC-006)
- [ ] T093 [P] [US4] Implement credit models (`WorkspaceCredits`, `CreditLedger`) in `backend-go/internal/credits/model/credit.go`
- [ ] T094 [US4] Implement credit fast-path service (Redis `DECRBY` atomic deduction, idempotency `SET NX billing:applied:{idem_key}`, near-limit detection, `402`/`429` blocking) in `backend-go/internal/credits/service/credits.go` (FR-016, FR-017, FR-018)
- [ ] T095 [US4] Implement the Go kernel billing worker as the **sole `credit_ledger` writer**, running in the `cmd/worker` role (not `cmd/api`): consume `billing.deduct.<ws>` spend events + **atomic** Redis-outbox pop (`LPOP`/Stream consumer-group) → ledger drain + cold-start rehydration (per-workspace lock); hourly reconciliation triggered by the external `billing.reconcile.tick` (pluggable: k8s `CronJob` / DO scheduled component / cron / single-owner `worker` ticker) and guarded by `SET NX reconcile:lock:{shard}:{hour_bucket}` so duplicate/concurrent ticks run once — in `backend-go/kernel/billing/reconcile.go` (FR-019, SC-006, research §15)
- [ ] T096 [P] [US4] Implement new-account/per-IP cumulative ceilings (relaxed only after `email_verified_at`) in `backend-go/internal/credits/service/abuse_guard.go` (FR-020)
- [ ] T097 [US4] Implement credits HTTP transport (`GET /credits`) + `SetupModule` in `backend-go/internal/credits/infra/transport/http/handler.go` and `backend-go/internal/credits/module.go`
- [ ] T098 [P] [US4] Implement the Python spend-event emitter (query/ingest/agent workers publish `billing.deduct.<ws>` with the cost computed at the call site from the standalone gateway's returned token usage; **never** writes `credit_ledger` or the Redis balance) in `backend-python/src/services/billing/emitter.py`
- [ ] T099 [P] [US4] Implement credit balance UI + near-limit warning banner with upgrade CTA in `frontend/src/features/chat/components/CreditBalance.tsx`

**Checkpoint**: US1–US4 work; credit accounting is exact, observable, and abuse-guarded.

---

## Stage 7: User Story 5 - Observable debug panel (Priority: P2)

**Goal**: For every answer, a developer-facing panel exposes intent, tool called, index tier, access-filter result, hybrid/RRF/rerank scores, chunk expansion, injected memory, model, token cost, credits deducted, and a Langfuse trace link.

**Independent Test**: Run a query and confirm the panel shows each retrieval/generation step with scores, access-filter result, token cost, and credits deducted.

### Tests for User Story 5 ⚠️ (write first, must fail)

- [ ] T100 [P] [US5] Contract test for `GET /query/{streamId}/debug` returning a fully populated `DebugTrace` (incl. `access_filter` count + `credits_deducted` + `langfuse_trace_url`) in `backend-go/tests/contract/debug_trace_test.go` per [sse-events.md](./contracts/sse-events.md) (FR-021, SC-005)

### Implementation for User Story 5

- [ ] T101 [US5] Implement debug-trace assembly in the LangGraph graph (capture intent, tool, HOT/COLD tier, access-filter count, BM25/vector/RRF/rerank-before/after scores, chunk_type, mem0_injected, model, token_cost) in `backend-python/src/services/agent/graph.py` (extends T073)
- [ ] T102 [US5] Surface `DebugTrace` through the Go `GET /query/{streamId}/debug` handler with `langfuse_trace_url` in `backend-go/internal/query/infra/transport/http/handler.go` (extends T076)
- [ ] T103 [P] [US5] Implement debug panel UI (per-step scores, access-filter summary, token cost, credits deducted, trace link) in `frontend/src/features/chat/components/DebugPanel.tsx` (FR-021)

**Checkpoint**: Every answer is fully observable; no step hidden (SC-005).

---

## Stage 8: User Story 6 - Admin usage dashboard (Priority: P3)

**Goal**: A workspace admin views per-user/per-feature AI usage, credit consumption, and cost, and manages member limits.

**Independent Test**: Generate usage across members; confirm the dashboard shows per-user/per-feature consumption and cost; adjusting a limit is enforced next op.

### Tests for User Story 6 ⚠️ (write first, must fail)

- [ ] T104 [P] [US6] Contract test for `GET /admin/usage` and `PATCH /workspaces/{id}/members/{userId}` limit enforcement in `backend-go/tests/contract/admin_usage_test.go` (FR-022)

### Implementation for User Story 6

- [ ] T105 [US6] Create `llm_call_log` table + `llm_cost_daily` materialized view migration (add the UNIQUE index required for `REFRESH MATERIALIZED VIEW CONCURRENTLY`; refreshed single-owner in `cmd/worker` via the `usage.matview.refresh` tick, research §15) in `backend-go/migrations/0013_llm_usage.sql` (FR-022, FR-024)
- [ ] T106 [US6] Implement admin usage service (aggregate per-user/per-feature from `llm_cost_daily`, enforce member-limit updates) in `backend-go/kernel/admin/usage.go` (FR-022)
- [ ] T107 [US6] Implement admin HTTP transport (`GET /admin/usage`, member-limit PATCH) + `SetupModule` in `backend-go/kernel/admin/transport/http/handler.go`
- [ ] T108 [P] [US6] Implement admin dashboard UI (per-user/per-feature usage + cost, member-limit controls) in `frontend/src/features/admin/`

**Checkpoint**: Admins can observe and govern usage.

---

## Stage 9: User Story 7 - Long-horizon tasks via a local agent (Priority: P3)

**Goal**: An optional local agent runs multi-step tasks using workspace-scoped tools, routing AI calls through the server by default (metered/audited); long tasks are durable, cancellable, and bounded by a per-task cost cap. All core features work with zero agents.

**Independent Test**: Register an agent, start a long-horizon task, interrupt the worker (resumes from checkpoint), cancel (cancelling→cancelled), and hit the `credits_cap` (halts), all metered/audited.

### Tests for User Story 7 ⚠️ (write first, must fail)

- [ ] T109 [P] [US7] Contract test for `POST /devices/authorize`, `GET/DELETE /devices/{id}`, `POST /llm/proxy` (PAT scope, token budget, credit deduction) in `backend-go/tests/contract/devices_test.go` (FR-025, FR-026)
- [ ] T110 [P] [US7] Contract test for `GET /agent-runs` + `POST /agent-runs/{id}/cancel` (`cancelling`→`cancelled`) and per-run `credits_cap` halt in `backend-go/tests/contract/agent_runs_test.go` (FR-028, SC-009)
- [ ] T111 [P] [US7] Integration test for long-horizon durability (worker kill → resume from checkpoint; stale-heartbeat janitor re-queue) in `backend-python/tests/integration/test_long_horizon.py` (FR-028, SC-009)
- [ ] T112 [P] [US7] Integration test confirming all core features work with zero connected agents in `backend-go/tests/integration/zero_agent_core_test.go` (FR-025, SC-008)

### Implementation for User Story 7

- [ ] T113 [US7] Create `devices`, `agent_policies`, `agent_audit_log`, `agent_run` migrations (partitioned where noted; `agent_run` checkpoint `state` JSONB, `credits_cap`/`credits_spent`) in `backend-go/migrations/0014_agents.sql` (FR-025–FR-028)
- [ ] T114 [P] [US7] Implement device + policy + agent-run models in `backend-go/internal/policy/model/device.go`, `policy.go`, and `agent_run.go`
- [ ] T115 [US7] Implement device registration service (issue scoped 90d PAT, list/revoke, `workspace_id` from PAT only) in `backend-go/internal/policy/service/device.go` (FR-025, FR-027)
- [ ] T116 [US7] Implement LLM proxy + policy chain (`POST /llm/proxy`: authenticate PAT, enforce `allowed_tools`/token budget, deduct credits, resolve alias, forward **as a synchronous HTTP streaming pass-through to the standalone LLM gateway `:4000`** — `stream:true` relays provider SSE verbatim, flush-per-chunk, no buffering; client disconnect cancels `request.Context()` → forwarded HTTP request → gateway stream; not gRPC/NATS, research §20/§21 — then trace; admin-disableable BYOK) in `backend-go/internal/policy/service/llm_proxy.go` (FR-026, FR-027)
- [ ] T117 [US7] Implement agent-run service (cancel propagation, per-step `credits_cap` check independent of daily budget) in `backend-go/internal/policy/service/agent_run.go` (FR-028, SC-009)
- [ ] T118 [P] [US7] Implement policy repository + `agent_audit_log` writer (`tool_called`, `token_cost`, `result_hash`, `trace_id`) in `backend-go/internal/policy/infra/repo/policy_repo.go` (FR-023)
- [ ] T119 [US7] Implement policy HTTP transport (`/devices/*`, `/llm/proxy`, `/agent-runs/*`) + `SetupModule` in `backend-go/internal/policy/infra/transport/http/handler.go` and `backend-go/internal/policy/module.go`
- [ ] T120 [US7] Implement Python long-horizon worker (durable LangGraph checkpoints to Redis AOF, heartbeat every 10s, cancel handling, per-run cap halt) in `backend-python/src/services/agent/long_horizon.py`; the stale-heartbeat re-queue runs in a **single-owner janitor role** triggered by the external `agent.janitor.tick` (not an in-process timer per pod) and re-queues via a conditional `UPDATE agent_run SET status='queued' WHERE id=$1 AND status='running' AND last_heartbeat_at < $2 RETURNING id` so concurrent janitors re-queue each run once (FR-028, SC-009, research §15)
- [ ] T121 [P] [US7] Implement device-management + agent-run UI (register/revoke device, run list, cancel) in `frontend/src/features/admin/components/Devices.tsx` and `AgentRuns.tsx`

**Checkpoint**: All 7 user stories independently functional; local agents are additive and fully metered/audited.

---

## Stage 10: User Story 8 - Stay informed through notifications (Priority: P3)

**Goal**: Recipient-scoped notifications for ingestion, invites, credit warning/exhaustion, task-halt, doc-shared, clearance-change, member-joined, and admin broadcast — persisted to an in-app inbox, pushed in real time over SSE, and (per opted-in category) delivered by email via a provider-agnostic port. Each member controls delivery per category × per channel.

**Independent Test**: Trigger an event for a recipient, confirm the in-app notification arrives in real time and increments the unread badge; mark read and confirm the badge decrements; disable a category's email channel and confirm a later event sends no email while still appearing in-app; confirm a second member never sees the first member's notifications.

### Tests for User Story 8 ⚠️ (write first, must fail)

- [ ] T129 [P] [US8] Contract test for `/notifications` list (`?unread=`, pagination), `/notifications/unread-count`, `/notifications/{id}/read` (404 for non-recipient), `/notifications/read-all`, `GET/PUT /notifications/preferences`, and `POST /admin/notifications/broadcast` in `backend-go/tests/contract/notifications_test.go` per [bff-rest.md](./contracts/bff-rest.md) (FR-032–FR-037)
- [ ] T130 [P] [US8] Contract test for `/notifications/stream` SSE taxonomy (initial `unread_count`, then `notification` + `unread_count` per event) in `backend-go/tests/contract/notifications_sse_test.go` per [sse-events.md](./contracts/sse-events.md) (FR-034)
- [ ] T131 [P] [US8] Integration test for recipient scoping — member A never receives/sees member B's notifications, and no cross-workspace leakage even at L5 (RLS) in `backend-go/tests/integration/notification_scoping_test.go` (FR-036, SC-012)
- [ ] T132 [P] [US8] Integration test for preference + channel fan-out: disabled email channel publishes no `notify.email.<ws>`; simulated email-provider failure routes to `notify.email.dlq.<ws>` while in-app delivery succeeds in `backend-go/tests/integration/notification_email_test.go` (FR-035)
- [ ] T132a [P] [US8] Integration test for idempotent delivery — the same `notify.<ws>` event delivered twice (same `idem_key`) yields exactly one persisted notification, one in-app push, and one `notify.email.<ws>` publish in `backend-go/tests/integration/notification_idempotency_test.go` (FR-032, SC-013)
- [ ] T132b [P] [US8] Integration test for coalescing — a burst of same-category events for one recipient produces a digest/rate-limited summary rather than one push + one email per event in `backend-go/tests/integration/notification_coalesce_test.go` (FR-038)
- [ ] T132c [P] [US8] Integration test for email suppression + unsubscribe — a send to a suppressed address is skipped (not retried); a valid unsubscribe token disables that category's `email` channel; an unsigned `/webhooks/email/{provider}` body is rejected in `backend-go/tests/integration/notification_suppression_test.go` and `backend-go/tests/contract/notifications_webhook_test.go` (FR-035)
- [ ] T132d [P] [US8] Contract/integration test for async broadcast — `POST /admin/notifications/broadcast` returns promptly, fans out per-recipient off the request path, and is audited in `backend-go/tests/integration/notification_broadcast_test.go` (FR-037)
- [ ] T132e [P] [US8] Integration test for `notify.email.dlq` drain via `dlq.sweep.tick` — a genuinely-unsent parked email is re-driven to `notify.email.<ws>` and delivered exactly once (mark-sent only after provider-accept; suppressed address skipped, not re-driven); an email reaching `MAX_DLQ_ATTEMPTS` lands in `dead_letters` with a `dlq.dead.count` emit and is not re-driven again in `backend-go/tests/integration/notification_dlq_drain_test.go` (research §18, FR-035)

### Implementation for User Story 8

- [ ] T133 [P] [US8] Implement notification + preference models in `backend-go/internal/notification/model/notification.go` and `preference.go` (categories, priority, payload, read state)
- [ ] T134 [US8] Implement notification service (consume `notify.<ws>` as a **JetStream queue-group consumer hosted in `cmd/worker`** so it scales out independently per-subject, resolve recipient prefs with category defaults, persist row **idempotently** via `(user_id, idem_key) UNIQUE` + `SET NX notify:applied:{idem_key}`, push in-app via Redis pub/sub `notify:user:<id>`, republish enabled emails to `notify.email.<ws>`) in `backend-go/internal/notification/service/notify.go` (FR-032–FR-035, SC-013)
- [ ] T135 [P] [US8] Implement inbox + preference repository (list/unread-count/mark-read/mark-all, prefs upsert) in `backend-go/internal/notification/infra/repo/notification_repo.go` (FR-033, FR-035)
- [ ] T136 [US8] Implement notification HTTP + SSE transport — inbox REST (`/notifications/*`) wired in `cmd/api`, and `/notifications/stream` relaying `notify:user:<id>` wired in `cmd/relay` (connection-bound, scales with relay replicas) — plus `/admin/notifications/broadcast` + `SetupModule` in `backend-go/internal/notification/infra/transport/http/handler.go` and `backend-go/internal/notification/module.go` (FR-033, FR-034, FR-037)
- [ ] T137 [US8] Wire producers to publish `notify.<ws>` events (each stamping a deterministic `idem_key` from the originating resource + event, SC-013) from existing flows (ingestion complete/failed, invite received/accepted/revoked, credit warning/exhausted, agent-run cost-cap halt, doc shared, clearance change, member joined) in their respective services (FR-032)
- [ ] T138 [P] [US8] Implement Go email worker (runs in `cmd/worker`, consumes `notify.email.<ws>`) using the `kernel/mailer.go` port with a default Resend adapter (env-swappable), `html/template` rendering with an unsubscribe link, `email_suppressions` skip-check, `idem_key`/`notification_id` dedup that marks an address **sent only after provider-accept** (so a DLQ re-drive of a genuinely-unsent mail still delivers, exactly once), retry with backoff, and `notify.email.dlq.<ws>` parking (stamping `dlq_attempts`/`first_failed_at`) in `backend-go/internal/notification/service/email_worker.go` and `backend-go/internal/platform/mailer/resend.go` (FR-035, research §18)
- [ ] T139 [P] [US8] Implement notification bell + inbox + per-category/per-channel preferences UI (live SSE badge, mark read/all, deep-link via payload) in `frontend/src/features/notification/`
- [ ] T140 [US8] Implement async admin-broadcast fan-out — enqueue one job from `POST /admin/notifications/broadcast` that publishes per-recipient `notify.<ws>` events off the request path, audited in `backend-go/internal/notification/service/broadcast.go` (FR-037)
- [ ] T141 [US8] Implement same-category coalescing/digest (rate-limited summary per recipient over a short window) in the notification service in `backend-go/internal/notification/service/coalesce.go` (FR-038)
- [ ] T142 [P] [US8] Implement notification retention job (prune/archive read notifications older than the configured window, default 90d; optional range-partition drop on `created_at`), triggered via the scheduler seam (`notify.retention.tick`) in `backend-go/internal/notification/service/retention.go` and wired in `cmd/worker` (FR-039)
- [ ] T143 [US8] Implement signature-verified email-provider webhook `POST /webhooks/email/{provider}` (upsert `email_suppressions` on bounce/complaint) and one-click `GET /notifications/unsubscribe` (signed token → disable category `email` channel) in `backend-go/internal/notification/infra/transport/http/webhook.go` (FR-035)

**Checkpoint**: All 8 user stories independently functional; notifications are recipient-scoped, real-time in-app, and email-deliverable per preference.

---

## Stage 11: Polish & Cross-Cutting Concerns

**Purpose**: Reliability, observability, retention, evaluation gate, and final validation across all stories

- [ ] T122 [P] Configure provider one-hop fallback + multi-key load-balancing + circuit breaker (never on low-quality output) in the **standalone LLM gateway** (`deploy/llm-gateway/config.yaml`, LiteLLM router; Bifrost-swappable) and export `llm.fallback.count`; verified via the gateway, not application code (FR-029, research §21)
- [ ] T123 [P] Implement the canonical PII scrubber in `backend-python/src/services/pii_scrub.py` (single implementation; the LLM gateway T026 is its only caller, covering both primary and one-hop-fallback calls) applied before any trace/eval write + 30-day raw-body retention via partition `DROP` job in `backend-go/migrations/0015_retention_jobs.sql` (FR-024, Clarification Q5)
- [ ] T124 [P] Implement generic `audit_log` writer (tamper-evident fingerprint) for workspace/member actions in `backend-go/kernel/audit/audit.go` (FR-023)
- [ ] T125 Implement Phase 1 eval seed set + runner (`evals/run.py`: ≥20 prompt cases; `prompts/retrieval/eval.py`: ≥30 golden queries) with the hard access-filter assertion (query at level N never returns doc > N) in `backend-python/evals/run.py` and `backend-python/prompts/retrieval/eval.py` (FR-030, SC-002, SC-003)
- [ ] T126 [P] Wire CI gates into `Makefile`/CI: lint+format (gofmt/golangci-lint, ruff/black, eslint/prettier), ≥80% coverage per runtime, Testcontainers integration runs (`go test -tags=integration` / `pytest -m integration`), Playwright E2E, performance/bundle-size checks, security scan, and the Phase 1 eval gate
- [ ] T127 [P] Implement Playwright E2E suite for the critical journeys (upload→indexed library; ask→cited streamed answer + debug panel; access-scoped visibility for two clearances; near-limit warning + exhaustion block) in `frontend/tests/e2e/` (SC-004, SC-005, SC-008, SC-010)
- [ ] T128 Execute [quickstart.md](./quickstart.md) validation Scenarios 1–8 end-to-end and record evidence (Principle X)

### Access-control adversarial hardening (SC-001, release blocker)

> SC-001 is a release blocker at "100%". Functional happy-path tests are insufficient — these property-based and adversarial tests cover **every** surface that touches authorized content: Qdrant retrieval, semantic cache, Mem0 memory, and Postgres RLS. The two non-negotiable gates are the deny-by-default filter guard (T140) and the zero-above-clearance eval assertion (T125).

- [ ] T140 [P] Property-based retrieval filter tests in `backend-python/tests/security/test_retrieval_filter_property.py` (Hypothesis): across randomized corpora over all 5 levels × both collections, assert no returned chunk has `access_level > requester_clearance` or a foreign `workspace_id`; assert a member B query never returns member A's personal-collection chunk even at L5; assert the **deny-by-default guard** (T027) raises when a search is attempted with no `workspace_id`/`access_level` filter (FR-007, SC-001)
- [ ] T141 [P] Cross-clearance semantic-cache adversarial tests in `backend-python/tests/security/test_cache_cross_clearance.py`: same normalized query at L4 then L2 → L4 populates, L2 is a **miss** and never receives L4 bytes; same clearance but different `user_id` for personal-scoped answers → also a miss; inject a unique sentinel into the L4 answer and assert it never appears in any L2 response across N runs (FR-007, SC-001, research §2)
- [ ] T142 [P] Memory temporal/adversarial tests in `backend-python/tests/security/test_memory_clearance.py`: extends T061a into a property test over write-clearance × read-clearance pairs — assert a memory is injected at Node 5 iff its stamped `access_level` ≤ the requester's current clearance, and a sentinel L4 fact is never surfaced after demotion (FR-009, SC-001, research §13)
- [ ] T143 [P] RLS negative tests in `backend-go/tests/security/rls_negative_test.go`: a tenant query executed without `SET LOCAL app.workspace_id` returns 0 rows / errors (never the full table); a forged `workspace_id` in the request body is ignored (resolved server-side) and RLS blocks cross-workspace reads (FR-014, SC-001)
- [ ] T144 Extend the Phase 1 eval gate (T125) with the **hard zero-above-clearance assertion** as a blocking CI check: across the full golden query set, no above-clearance labeled doc ID appears in any answer's citations or retrieved set; non-zero violations fail the build (FR-030, SC-001)

---

## Dependencies & Execution Order

### Stage Dependencies

- **Setup (Stage 1)**: No dependencies — start immediately
- **Foundational (Stage 2)**: Depends on Setup — **BLOCKS all user stories**
- **User Stories (Stages 3–10)**: All depend on Foundational completion
  - US1 (P1) and US2 (P1) form the MVP; US2 retrieval/agent depends on US1 ingestion having indexed content for meaningful end-to-end tests, but both can be developed in parallel against fixtures
  - US3–US8 can proceed in parallel once Foundational is done (if staffed)
- **Polish (Stage 11)**: Depends on the targeted user stories being complete

### User Story Dependencies

- **US1 (P1)**: After Foundational — no dependency on other stories
- **US2 (P1)**: After Foundational — consumes US1's indexed chunks at runtime; independently testable via seeded fixtures
- **US3 (P2)**: After Foundational — independently testable; strengthens access scoping US1/US2 already honor
- **US4 (P2)**: After Foundational — metering hooks into US1/US2 AI ops; independently testable
- **US5 (P2)**: After US2 (extends the query graph + debug endpoint)
- **US6 (P3)**: After Foundational — reads `llm_call_log` populated by US2/US4
- **US7 (P3)**: After Foundational — reuses credits (US4) + MCP tools (US2); core works with zero agents (SC-008)
- **US8 (P3)**: After Foundational — consumes events produced by US1/US3/US4/US7 flows; independently testable via a directly published `notify.<ws>` event; recipient-scoping is a release blocker (SC-012)

### Within Each User Story

- Tests written first and FAIL before implementation (Principle VI)
- Models → services → endpoints → integration
- Migrations precede repositories that read the tables

### Parallel Opportunities

- All Setup tasks marked [P] run in parallel
- All Foundational [P] tasks within their subsection run in parallel
- Once Foundational completes, US1–US8 can be staffed in parallel
- All [P] test tasks within a story run in parallel (different files)
- All [P] models within a story run in parallel

---

## Parallel Example: User Story 1

```bash
# Launch all US1 tests together (write first, must fail):
Task T035: "Contract test for POST /ingest/presign in backend-go/tests/contract/ingest_presign_test.go"
Task T036: "Contract test for /notes + enrich SSE + accept + status in backend-go/tests/contract/ingest_test.go"
Task T037: "Contract test for ingestion NATS subjects in backend-python/tests/contract/test_ingestion_subjects.py"
Task T038: "Integration test for ingestion pipeline in backend-python/tests/integration/test_ingestion_pipeline.py"
Task T039: "Contract test for /documents in backend-go/tests/contract/documents_test.go"

# Then launch parallel converters/captioner/distiller:
Task T049: "MarkItDown converter in backend-python/src/services/ingestion/markitdown.py"
Task T050: "Image captioner in backend-python/src/services/ingestion/captioner.py"
Task T051: "Shared web_distill capability in backend-python/src/services/ingestion/web_distill.py"
Task T051a: "Note-enrich worker in backend-python/src/services/ingestion/enrich.py"
```

---

## Implementation Strategy

### MVP First (User Stories 1 + 2)

1. Complete Stage 1: Setup
2. Complete Stage 2: Foundational (CRITICAL — blocks all stories; includes RLS, LLM gateway, MCP server, access filter)
3. Complete Stage 3: US1 (ingest → library)
4. Complete Stage 4: US2 (ask → cited, access-scoped answer)
5. **STOP and VALIDATE**: quickstart Scenarios 1, 2, 4 (ingest→answer, access scoping, injection refusal)
6. Deploy/demo the core knowledge loop

### Incremental Delivery

1. Setup + Foundational → foundation ready
2. US1 + US2 → MVP knowledge loop → demo
3. US3 → multi-tenant access control → demo
4. US4 → credit metering/budgets → demo
5. US5 → debug observability → demo
6. US6 → admin dashboard → demo
7. US7 → optional local agents / long-horizon → demo
8. Polish → reliability, retention, eval gate, full quickstart validation

### Parallel Team Strategy

1. Whole team completes Setup + Foundational together
2. Once Foundational is done:
   - Dev A: US1 (ingestion)
   - Dev B: US2 (retrieval/agent) against fixtures
   - Dev C: US3 (workspace/access) + US4 (credits)
3. US5 follows US2; US6/US7 pick up after Foundational as capacity allows

---

## Notes

- [P] = different files, no incomplete-task dependencies
- [Story] label maps each task to its user story for traceability
- Access control is enforced at the data layer (Postgres RLS + Qdrant payload pre-filter) in Foundational and every story — never by prompt (SC-001, release blocker)
- Verify tests fail before implementing (Red→Green→Refactor, Principle VI)
- Integration tests provision real Postgres/Redis/NATS/Qdrant via Testcontainers; critical journeys are covered by Playwright E2E (never mocked infra for these layers)
- Claim a task done only with verification evidence (Principle X)
- Commit after each task or logical group
- Stop at any checkpoint to validate a story independently
