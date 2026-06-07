# Phase 0 Research: AISAT-STUDIO MVP (Phase 1)

**Date**: 2026-06-06 | **Plan**: [plan.md](./plan.md)

All Technical Context items are resolved; the spec carries no remaining `NEEDS CLARIFICATION` markers (five were resolved in the Clarifications session on 2026-06-05). This document records the load-bearing technical decisions, their rationale, and rejected alternatives.

## 1. Access-control enforcement (data layer, not prompt)

- **Decision**: Enforce isolation at two layers: PostgreSQL Row-Level Security (`workspace_id = current_setting('app.workspace_id')`) on every tenant-scoped table, and Qdrant payload pre-filters (`workspace_id` match + `access_level Range(lte=user_access_level)`) injected before every vector search. Clearance is a fixed ladder of 5 ordered levels (1–5); a document with no explicit level defaults to the uploader's own clearance.
- **Rationale**: SC-001 is a hard release blocker (100% correctness). Prompt-level instructions are bypassable by injection; data-layer filters are not. Two independent layers give defense in depth — RLS protects relational reads, payload filters protect vector reads.
- **Alternatives considered**: (a) Prompt-only scoping — rejected: trivially defeated and untestable. (b) One Qdrant collection per workspace — rejected: collection sprawl and cost; payload isolation with indexed fields scales better for Phase 1. (c) Application-layer filtering after retrieval — rejected: leaks restricted docs into process memory and risks accidental inclusion.

## 2. Cross-clearance semantic cache keying

- **Decision**: Cache key = `sha256(workspace_id | user_id | effective_access_level | model | normalize(query))`. Personal-knowledge answers cache per-user; workspace-only answers MAY cache per `(workspace_id, access_level)` via a `cacheable_scope` flag the retriever sets when no personal document contributed.
- **Rationale**: The same query string legitimately resolves to different documents per clearance, so a query-only key would leak a higher-clearance answer to a lower-clearance member (violates SC-001). Binding tenant + identity + clearance makes a cache hit reusable only within an identical authorization scope (Clarification Q2).
- **Alternatives considered**: (a) Query-only key — rejected: cross-clearance leak. (b) No caching — rejected: needlessly sacrifices latency/cost; safe caching is achievable. (c) Per-user only for everything — rejected: lower hit rate; workspace-only answers can safely share.

## 3. Credit accounting: Redis hot path + Postgres ledger

- **Decision**: Redis holds the authoritative hot balance (`DECRBY`, atomic); PostgreSQL `credit_ledger` (append-only, `idem_key UNIQUE`) is the durable source of truth, written async via a Redis outbox drained by a Python billing worker. Every credit-affecting operation carries an idempotency key; a `SET NX billing:applied:{idem_key}` guard plus the ledger unique index make retries/double-clicks no-ops. Cold-start rehydration rebuilds the Redis balance from the ledger under a per-workspace lock; an hourly reconciliation cron corrects drift with `operation_type='reconcile'` rows.
- **Rationale**: SC-006 demands exact accounting and no double-charge. Atomic Redis decrement gives sub-ms enforcement on the hot path; the durable ledger guarantees recoverability and auditability; idempotency closes the retry double-charge hole.
- **Alternatives considered**: (a) Postgres-only synchronous deduction — rejected: too slow on the hot path, lock contention. (b) Redis-only — rejected: not durable; a Redis loss is a billing incident. (c) Best-effort ledger write — rejected: drops under failure; the outbox makes deduction and ledger intent atomic.

## 4. Provider fallback strategy (one-hop)

- **Decision**: LLM aliases (`fast`, `smart`, `embed`, `rerank`) resolve to `{primary, fallback}` in the Python `llm_gateway`. Fail over on timeout / 5xx / rate-limit only, capped at one hop, with an `llm.fallback.count` metric and a circuit breaker. `embed` has **no per-call fallback**: a down primary embedder parks the chunk in `ingestion.dlq` for retry rather than embedding with a different model.
- **Rationale**: Edge case + FR-029 require degradation, not outage, while never failing over on "low-quality" output (that is an eval concern). Embedding models cannot be mixed within one Qdrant collection without making distances meaningless, so per-call embed fallback would silently corrupt retrieval quality.
- **Alternatives considered**: (a) Multi-hop fallback — rejected: unbounded latency. (b) Quality-based fallback — rejected: undefined/abusable signal, not a reliability event. (c) Per-call embed fallback — rejected: index inconsistency.

## 5. Prompt-injection structural defenses (Phase 1, not deferred)

- **Decision**: Ship the structural defenses in Phase 1: (1) retrieved content wrapped in `<retrieved_document>` delimiters with a system rule that delimited text is data, never commands; (2) tool results never trigger new tool calls without the router re-deriving intent from the original classified intent; (3) strict per-role `allowed_tools` allowlist enforced on every dispatch; (4) read-only-only Phase 1 toolset (no write/send tools); (5) audit + `result_hash` on every tool call. A Node 0 moderation gate short-circuits disallowed/injection inputs before any retrieval or spend.
- **Rationale**: Uploaded files and crawled pages are untrusted content on the core data path — the textbook injection vector. These defenses are cheap, are not a scanning tool, and are required for FR-010/FR-011/FR-012 and SC-007. Automated red-teaming (Garak) is Phase 3 and layers on top, not a replacement.
- **Alternatives considered**: Deferring all injection handling to Phase 3 — rejected: leaves the core data path exposed during Phase 1.

## 6. Async agent execution over NATS (not in-process)

- **Decision**: The Go BFF publishes queries to `query.agent.<workspace_id>` and returns an SSE stream ID; a Python worker pool consumes, runs the LangGraph 7-node graph, checkpoints state to Redis (AOF), and streams partial results via Redis pub/sub → Go SSE → browser. Only `intent=long_horizon` runs create a durable `agent_run` row; short interactive queries do not.
- **Rationale**: Decouples request latency from model latency, enables independent worker scaling per NATS subject (KEDA on consumer lag in Phase 2), and survives worker restarts via checkpoints. Matches the streaming UX (SSE event taxonomy) and the durability needs of long-horizon tasks (SC-009).
- **Alternatives considered**: (a) In-process LangGraph per HTTP request — rejected: couples latency, no durability, poor scaling. (b) WebSockets — rejected: SSE is sufficient for server→client streaming and simpler behind CDN.

## 7. Structured (Tier 2) data access: fixed tools, not Text-to-SQL

- **Decision**: Structured-data questions are answered by fixed, parameterized, workspace-scoped MCP tools (`query_employees`, `query_projects`, `query_metrics`). The LLM chooses a tool and supplies typed arguments; the SQL is hand-written and scoped — never free-form generated SQL.
- **Rationale**: FR-008 + SC-001. Free-form generated SQL is an injection and data-exfiltration risk and cannot be reliably scoped to a workspace/clearance. Fixed tools keep the access boundary in code.
- **Alternatives considered**: Free-form Text-to-SQL — rejected: unbounded query surface, unsafe across tenants.

## 8. Ingestion pipeline + upload boundary

- **Decision**: Browser uploads directly to S3 via presigned URL; an S3 event publishes to `ingestion.{mime}.{workspace_id}`; Python workers route by MIME (MarkItDown for PDF/DOCX/MD, GPT-4o-mini captioning for images, Crawl4AI for links; video/audio is a registered-but-501 stub). BAML extracts advisory metadata (tags/data_type/summary/suggested_sensitivity); security fields are stamped server-side. A per-file size limit (admin-configurable per workspace, default 50 MB) is enforced at the upload boundary before any ingestion or spend.
- **Rationale**: Direct-to-S3 keeps large payloads off the app servers; MIME routing matches FR-001/FR-002/FR-003; the size limit (Clarification Q4) bounds cost and processing time and gives a clear oversize rejection rather than silent failure.
- **Alternatives considered**: (a) Proxying uploads through the BFF — rejected: memory/bandwidth pressure. (b) Model-inferred access level — rejected: a malicious upload could self-tag permissive (FR-004/FR-005).

## 9. PII scrubbing & retention window

- **Decision**: A PII filter runs in the gateway **before** any prompt/response is written to a trace or eval store. Raw prompt/response bodies are retained for a **30-day** window, after which they are purged (partition `DROP`) and only metadata, hashes, and aggregates remain. `llm_call_log` and `agent_audit_log` never store raw message bodies — only metadata, token counts, and hashes.
- **Rationale**: FR-024 + Clarification Q5 fix the window at 30 days. Scrub-before-write minimizes PII exposure; partition-drop expiry is cheap and tombstone-free. (Note: the source draft mentioned a 7-day Langfuse window; the clarified spec value of 30 days is authoritative and supersedes it.)
- **Alternatives considered**: (a) Indefinite raw retention — rejected: privacy/compliance risk. (b) Scrub-after-store — rejected: raw PII briefly persists. (c) Row-delete expiry — rejected: expensive, leaves tombstones.

## 10. Redis role separation (single cluster, logical split)

- **Decision**: Phase 1 runs one Redis cluster but separates roles by logical DB + key-prefix: durable state (credit balance, idempotency keys, `agent_run` checkpoints) runs `noeviction` + AOF; ephemeral cache (semantic/exact cache, hot-index flags) runs `allkeys-lru`, AOF off; counters (rate limits, daily budgets) run `volatile-ttl`. Pub/Sub for SSE fan-out is transient.
- **Rationale**: These roles have incompatible durability/eviction profiles — an LRU policy correct for the cache would silently evict credit balances or in-flight checkpoints (a billing/data incident). Logical separation makes the Phase 2 split into independent clusters a config change, not a refactor.
- **Alternatives considered**: One Redis with a single eviction policy — rejected: cache pressure would evict durable state.

## 11. Local agents (optional, additive)

- **Decision**: Local agents are optional; all core features work with zero agents (SC-008). A registered device gets a scoped, revocable PAT (user + workspace). Default `proxy` sub-mode routes LLM calls through `/llm/proxy` (metered, moderated, audited); `byok` sub-mode bypasses server LLM metering/moderation but still routes MCP tool calls server-side and is disableable per workspace by an admin. All agent results are untrusted; tool arguments are validated against the PAT scope. Long-horizon runs are durable with a hard per-run `credits_cap`.
- **Rationale**: FR-025–FR-028 + SC-008/SC-009. Optionality keeps the core product independent of agents; the proxy default preserves metering/audit; BYOK is an explicit, admin-gateable trade-off.
- **Alternatives considered**: Making agents mandatory for any feature — rejected: violates SC-008.

## Resolved unknowns summary

| Item | Resolution | Source |
|------|------------|--------|
| Clearance levels & default | Fixed ladder 1–5; default = uploader clearance | Clarification Q1 |
| Cache keying | workspace + clearance + authorized doc set | Clarification Q2 |
| Near-limit warning threshold | Admin-configurable per workspace, default 80% | Clarification Q3 |
| Per-file upload size limit | Admin-configurable per workspace, default 50 MB | Clarification Q4 |
| Raw prompt/response retention | 30 days, then metadata/aggregates only | Clarification Q5 |
| Embedding fallback | None per-call; park in DLQ | FR-029 + §1 caveat |
| Structured data access | Fixed parameterized tools, not Text-to-SQL | FR-008 |
