# Implementation Plan: AISAT-INTEL MVP — AI-Powered Shared Second Brain (Phase 1)

**Branch**: `001-contextengine-mvp` | **Date**: 2026-06-06 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-contextengine-mvp/spec.md`

## Summary

AISAT-INTEL (ContextEngine) is an AI-powered shared second brain for work teams: members ingest files/links/notes; the system converts, auto-tags, chunks, embeds, and indexes them; a stateful RAG agent answers natural-language questions with citations, scoped strictly to what the requester is cleared to see. Access control is enforced at the data layer (Postgres RLS + Qdrant payload pre-filters), never by prompt. Every AI operation is metered against a workspace credit balance, and every answer is observable in a developer-facing debug panel.

Technical approach: a three-runtime system — a Go BFF/gateway (kernel + agent policy layer) fronting a Python ML/agent tier (LangGraph 7-node RAG graph, ingestion pipeline, MCP tool server) and a React (Vite) SPA — coordinated over NATS, with PostgreSQL (RLS) as the durable store, Redis as the hot path (credits, checkpoints, semantic cache, rate limits), Qdrant for hybrid vector search, and S3 for object storage. LLM access is funneled through a **standalone, OpenAI-wire gateway service** (LiteLLM in Phase 1, Bifrost-swappable — `fast`/`smart`/`embed`/`rerank` aliases, multi-key load-balancing, one-hop provider fallback; research §21) called by both runtimes, wrapped by a thin per-runtime client (clearance-cache, PII scrub, spend emission) and the Go middleware policy chain; observability is via Langfuse + OpenTelemetry.

## Technical Context

**Language/Version**: Go 1.23 (BFF, gateway, middleware, kernel) · Python 3.12 (ML/AI workers, LangGraph agent, ingestion, MCP server) · TypeScript 5.x + React 19 (Vite SPA)

**Primary Dependencies**:
- Go: Gin (HTTP), GORM (Postgres), nats.go, go-redis, OpenTelemetry, zerolog, Sentry; `testcontainers-go` (containerized integration deps)
- Python: FastAPI, LangGraph, Mem0, BAML, FastMCP, MarkItDown, Crawl4AI, qdrant-client, `openai` (client pointed at the LLM gateway URL), structlog, Langfuse SDK; `testcontainers-python` (containerized integration deps)
- LLM gateway: **LiteLLM** as a standalone OpenAI-wire service (Bifrost/Portkey-swappable — research §21) — the only holder of provider keys; owns aliases (`fast`/`smart`/`embed`/`rerank`), multi-key load-balancing, and one-hop fallback
- Frontend: React 19, Vite, TypeScript, native EventSource/SSE client, PostHog (product analytics); Vitest (unit/component) + Playwright (cross-browser E2E)
- Auth provider: Casdoor (`casdoor.Auth` implementation of the kernel `Auth` interface; swappable with `jwt.Auth`/`workos.Auth`). Browser sessions use **OIDC Authorization Code + PKCE**; the BFF issues an **opaque session token** (HttpOnly cookie, Redis-backed, instantly revocable). Local agents use scoped device PATs. Full sequences: [contracts/auth-flow.md](./contracts/auth-flow.md)
- Edge/proxy: Caddy (reverse proxy, automatic TLS, static SPA serving) in front of the BFF
- Eval stack: Promptfoo + DeepEval (prompt/LLM-output assertions) and Ragas (retrieval/RAG metrics) — Phase 1 wires a minimal subset behind `evals/run.py`; the full suite is Phase 2
- Deferred (Phase 2): Whisper (audio transcription) — the `ingestion.audio` track is a `501` stub in Phase 1

**Storage**: PostgreSQL (primary relational + RLS isolation) · Redis (hot index TTL 30d, credit fast path, LangGraph checkpoints, semantic cache, rate limiting, outbox queue) · Qdrant (2 collections: `personal`, `workspace`; hybrid BM25/SPLADE + dense) · S3 (presigned direct upload)

**Testing**: Go `go test` (+ `-cover`) with **Testcontainers** (`testcontainers-go`) for `//go:build integration` runs against real Postgres/Redis/NATS/Qdrant · Python `pytest` (+ `--cov`) with **Testcontainers** (`testcontainers-python`) for ingestion/agent integration · Frontend `vitest` (unit/component) and **Playwright** (cross-browser E2E of the critical journeys) · `evals/run.py` (Phase 1 minimal eval runner — prompt + golden retrieval set, using a Promptfoo/DeepEval/Ragas subset)

**Target Platform**: Linux server containers (Docker / Docker Compose for local dev; a top-level `Makefile` is the canonical task entrypoint for build/test/lint/run/migrate/eval across all three runtimes); Caddy as the reverse proxy / TLS termination and static SPA host at the edge; browser SPA delivered via CloudFront CDN in production

**Project Type**: Web application — multi-runtime (Go backend + Python ML tier + React frontend)

**Performance Goals**: API p95 < 200ms (non-LLM paths, per constitution); first upload → cited answer < 5 min (SC-004); retrieval `recall@10` ≥ 0.85 pre-rerank, `recall@5` ≥ 0.80 post-rerank, `MRR@10` ≥ 0.70 (SC-002/SC-003); initial web interactive < 2.5s

**Constraints**: 100% access-control correctness (SC-001, release blocker); injection/disallowed inputs refused before retrieval/spend (SC-007); exact credit accounting, no double-charge (SC-006); per-file upload size limit admin-configurable per workspace, default 50 MB; raw prompt/response retention 30 days; near-limit warning at admin-configurable threshold (default 80%); one-hop provider fallback only

**Scale/Scope**: Phase 1 capacity — Go BFF 2 replicas, 3 Python worker pods per NATS subject (plus the Crawl4AI `crawl` worker and the standalone LLM gateway (LiteLLM) as their **own deployments**), single Qdrant/NATS cluster, Postgres primary + 1 read replica; 8 user stories, ~39 functional requirements, 12+ key entities, 8 MCP tools. **Scale-forward seams locked in Phase 1 (rework-risk, research §14–§15):** NATS runs in **JetStream** mode (durable pull consumers + per-subject queue groups); the SSE relay is a logically separable tier from the request-handling BFF; the Redis credit outbox is workspace-partitionable; Qdrant stays payload-isolated with a documented re-shard/replication trigger; scheduled/background work runs single-owner in a dedicated `cmd/worker` role (external CronJob → NATS tick → queue group, idempotent atomic claims — no in-process timers). Horizontal-scale *provisioning* (KEDA autoscaling, PgBouncer, Redis/Qdrant HA, SSE connection ceilings, load testing) is deferred to **Phase 4** ([draft-plan.md — Phase 4](../draft-plan.md#phase-4-scalability-and-resilience-hardening)).

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution v2.1.0 — ten core principles evaluated:

| Principle | Assessment | Status |
|-----------|------------|--------|
| **I. Code Quality (NON-NEGOTIABLE)** | Stack matches mandated ecosystems (Go/Python/React). Plan adopts a kernel/product split with `golangci-lint depguard` to prevent kernel→product imports. Lint/format tooling (gofmt/golangci-lint, ruff/black, eslint/prettier) is part of the CI gate; complexity ceiling and constants-over-magic-values enforced via lint. | PASS |
| **II. Clean Architecture (layered)** | High-level kernel/product split retained; the product tier is organized **feature-first** inside `internal/<feature>/{model,dto,errors,service,infra}` (Go), with mirrored feature folders in Python (`src/<feature>/`) and React (`src/features/<feature>/`). Consumer-defined interfaces; external services (Auth/Bus/Storage) behind kernel interfaces; DI only at the app root via `SetupModule`. | PASS |
| **III. API-First / Contract-First** | All boundaries are declared as contracts before implementation: OpenAPI-shaped REST, NATS subjects, MCP tools, SSE taxonomy, LLM gateway (see `contracts/`). REST versioned under `/api/v1/`. Unified error envelope. | PASS |
| **IV. Modular Design & Feature Flags** | Each feature wires itself via `SetupModule(appCtx)`; only `cmd/api/main.go` performs wiring. New user-facing behavior gated behind the kernel `Flags` interface; modules are independently removable. | PASS |
| **V. Testing Standards** | Layered suite: table-driven + parallel Go unit tests, `//go:build integration` integration tests against containerized deps via **Testcontainers** (`testcontainers-go`/`testcontainers-python` spin up real Postgres/Redis/NATS/Qdrant per run), contract tests per boundary, and **Playwright** E2E for critical journeys. 80% coverage floor per runtime; hard access-filter assertion in the eval seed set (FR-030). | PASS |
| **VI. Test-Driven Development (NON-NEGOTIABLE)** | Red-Green-Refactor mandated; contracts precede handlers/workers; test commits precede/accompany implementation (verifiable in git history). | PASS |
| **VII. Backend for Frontend (BFF)** | Go BFF shapes responses to SPA view-models, aggregates downstream calls, holds no core business logic. Responses mirror UI structure with consistent field naming, stable list keys, and shared enums for codegen. | PASS |
| **VIII. UX Consistency** | Shared React design system; SSE event taxonomy is a single typed contract; canonical `{code,message,details}` error schema unified across Go/Python; ISO-8601 UTC timestamps; integer credits. WCAG 2.1 AA applies to all new screens. | PASS |
| **IX. Performance Requirements** | Performance budgets defined in Technical Context. Hot/cold routing, payload indexes, RLS, Redis fast path, and semantic cache address N+1 / hot-path concerns; `EXPLAIN`-validated queries. Langfuse + OTel provide production measurement. | PASS |
| **X. Verification Before Completion (NON-NEGOTIABLE)** | Tasks are claimed done only with evidence — the verifying commands (`go test`/`pytest`/`vitest`, Testcontainers integration runs, Playwright E2E, lint, build, the Phase 1 eval gate) and their actual output, plus failing→passing runs for bug fixes (Principle VI). Unverified items reported as unverified. | PASS |

**Security/Technology constraints**: OWASP Top 10 — access control enforced at data layer (RLS + payload filter), untrusted-content (prompt-injection) structural defenses ship in Phase 1, secrets from environment only, idempotency on credit-affecting calls. No constitutional violations.

**Initial Constitution Check: PASS** — Complexity Tracking intentionally empty.

## Project Structure

### Documentation (this feature)

```text
specs/001-contextengine-mvp/
├── plan.md              # This file (/speckit.plan command output)
├── spec.md              # Feature specification (with Clarifications)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
│   ├── README.md            # Contract index + conventions
│   ├── bff-rest.md          # Go BFF public REST + SSE endpoints
│   ├── nats-subjects.md     # NATS subject schema (ingestion/query/billing)
│   ├── mcp-tools.md         # 8 MCP tools across 3 categories
│   ├── llm-gateway.md       # LLM gateway service (LiteLLM/Bifrost-swappable) + per-runtime client
│   └── sse-events.md        # SSE event taxonomy (BFF ↔ frontend)
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
backend-go/                      # Go BFF, gateway, kernel (template-level + product)
├── cmd/api/
│   ├── main.go                  # build appCtx (platform clients) + call each feature's SetupModule
│   └── routes.go                # shared router
├── cmd/relay/
│   └── main.go                  # SSE-relay entrypoint — same image, mounts only the streaming GET routes;
│                                #   subscribes to Redis pub/sub by stream_id and forwards (research §14)
├── cmd/worker/
│   └── main.go                  # background/scheduled role — same image; hosts two kinds of JetStream consumers:
│                                #   (a) scale-out queue-group consumers (notify.<ws> fan-out, notify.email.<ws> email worker) — N replicas, idempotent;
│                                #   (b) single-owner scheduled jobs (*.tick/*.refresh + outbox + dlq.sweep → capped re-drive then dead_letters + notify.retention.tick) — idempotent atomic claims, no in-process timers (research §15, §18)
├── kernel/                      # template-level; never imports product (depguard-enforced)
│   ├── auth.go bus.go storage.go mailer.go meter.go flags.go cache.go actor.go
│   └── identity/ tenancy/ billing/ notifications/ audit/ flags/ files/ observability/ admin/
├── internal/                    # product tier — feature-first (Principle II)
│   ├── platform/                # concrete infra clients: postgres/ redis/ qdrant/ nats/ otel/ logger/
│   ├── shared/                  # cross-cutting: dto/ errors/ middleware/ model/
│   ├── workspace/               # feature: module.go, model/, dto/, errors/, service/, infra/{repo/db,transport/http}
│   ├── invite/                  # feature: same internal layout
│   ├── credits/                 # feature: ledger service + repo + transport
│   ├── ingest/                  # feature: presign/transport + ingestion orchestration
│   ├── query/                   # feature: query transport + SSE relay
│   ├── notification/            # feature: notify service (fan-out + prefs), inbox repo, SSE relay, admin broadcast, email worker via kernel/mailer.go (US8)
│   └── policy/                  # feature: agent-gateway policy + repo
├── migrations/                  # SQL migrations (RLS policies, partitions)
└── tests/                       # contract, integration (//go:build integration, Testcontainers), e2e

backend-python/                  # ML/AI workers, agent, ingestion, MCP server
├── src/
│   ├── routers/                 # ingest, notes (enrich), query, admin (FastAPI)
│   ├── services/
│   │   ├── llm_gateway.py       # thin client to the standalone LLM gateway (LiteLLM/Bifrost): clearance-cache, PII scrub, budget gate, spend emit, trace; Headroom pre-send seam (research.md §12, §21)
│   │   ├── ingestion/           # pipeline, chunker, captioner, markitdown, web_distill, enrich, tagger (Crawl4AI fetch → separate `crawl` image/deployment, headless browser)
│   │   ├── retrieval/           # hybrid, reranker, hot_cold, filter
│   │   └── agent/               # graph (8 nodes: 7 RAG + Node 7 suggestions), memory (Mem0), cache (semantic), suggestions (FR-031); long-horizon worker + stale-heartbeat janitor (deployed as a single-owner janitor role, research §15)
│   ├── mcp_server/              # server.py + tools/{knowledge,structured,utility}; spend emitted via services/billing (Go kernel is the sole credit_ledger writer)
│   ├── baml_client/             # generated BAML client
│   └── schemas/                 # ingest, query, agent, billing
├── prompts/                     # query_rewrite/, metadata_extract/, image_caption/, response_format/, retrieval/
├── evals/run.py                 # Phase 1 minimal eval runner
└── tests/                       # contract, integration, unit

frontend/                        # React 19 + Vite SPA
├── src/
│   ├── features/                # feature-first: chat/, library/, upload/, admin/, workspace/
│   │   └── <feature>/           #   components/, hooks/, api/, types/ per feature
│   ├── components/              # shared design-system primitives only
│   ├── lib/                     # api.ts, sse.ts
│   └── types/                   # cross-cutting shared types
└── tests/                       # vitest (unit/component) + Playwright (e2e/)

deploy/
├── docker-compose.yml           # local dev: postgres, redis, qdrant, nats, casdoor, llm-gateway (LiteLLM :4000), services
├── llm-gateway/                 # standalone LLM gateway config (LiteLLM config.yaml; Bifrost-swappable) — aliases, provider keys, LB routing (research §21)
└── Caddyfile                    # reverse proxy, automatic TLS, static SPA serving

Makefile                         # canonical task runner: up/down, build, test, lint, migrate, eval, dev
```

**Structure Decision**: Web application with three runtimes plus shared infra. Per constitution Principle II, the architecture is **layered**: a high-level kernel/product split in Go (`kernel/` is template-level and never imports product code, enforced by `golangci-lint depguard`), and a **lower-level feature-based** organization inside each runtime's product tier — Go `internal/<feature>/{model,dto,errors,service,infra}` wired by `SetupModule(appCtx)`, Python `src/<feature>/`, and React `src/features/<feature>/`, each with a shared/platform layer for cross-cutting concerns. Authentication is provided through the swappable kernel `Auth` interface (Casdoor in this deployment). All LLM access funnels through a **standalone LLM gateway service** (LiteLLM, Bifrost-swappable — research §21), called by both runtimes via a thin client (`llm_gateway.py` in Python) that adds the clearance-cache / PII-scrub / spend-emission the service must not own; all tool access goes through the MCP server (shared platform chokepoints), mirroring the Go policy chokepoint. The frontend is a single SPA consuming the BFF over REST + SSE, served behind Caddy (reverse proxy + automatic TLS) locally and CloudFront in production. NATS (in **JetStream** mode — durable pull consumers + per-subject queue groups) is the async seam between Go and Python; Redis/Postgres/Qdrant/S3 are shared backing stores. The one Python worker peeled out of the shared image is **crawl** (Crawl4AI): it drives a headless browser, so it deploys as its **own image** rather than co-located on the shared worker pods — keeping that footprint and blast radius isolated (it serves only the member-initiated note-enrichment fetch, FR-001). Four scale-forward seams are locked here in Phase 1 to keep Phase 4 additive (research §14): JetStream durability, a separable SSE-relay tier, a workspace-partitionable credit outbox, and a documented Qdrant re-shard trigger. Mirroring the Python tier's one-image/many-worker-roles model, the Go BFF is a **single image with two entrypoints** — `cmd/api/main.go` (REST aggregation) and `cmd/relay/main.go` (SSE streaming) — sharing all `internal/` code; Phase 1 MAY run them as one deployment, and Phase 4 deploys them as independently-scaled `api` and `sse-relay` services (the relay scales on active-connection count, not CPU).

## Complexity Tracking

> No constitutional violations identified. The multi-runtime structure is justified by the spec's intrinsic requirements (Go for the policy/credit gateway, Python for the ML/agent ecosystem, React for the SPA) and is the standard topology for this class of product — not added complexity. Table intentionally empty.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| — | — | — |
