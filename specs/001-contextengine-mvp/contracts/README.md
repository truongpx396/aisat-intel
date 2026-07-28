# Contracts: AISAT-INTEL MVP (Phase 1)

**Date**: 2026-06-06 | **Plan**: [../plan.md](../plan.md)

These contracts define the external/internal interfaces the system exposes. They are the test targets for contract + integration tests (constitution Principle II) and the source of truth for the boundaries between the Go BFF, the Python ML tier, the MCP tool surface, and the React SPA.

## Files

| Contract | Surface | Consumers |
|----------|---------|-----------|
| [bff-rest.md](./bff-rest.md) | Go BFF public REST + SSE endpoints | React SPA, local agents |
| [auth-flow.md](./auth-flow.md) | Browser OIDC (PKCE) + device PAT auth sequences | React SPA, local agents |
| [authorizer-ports.md](./authorizer-ports.md) | Reusable `Authorizer`/`Policy`/`Lowerer` ports — one predicate lowered to RLS **and** Qdrant (parity), the swappable access-model seam | Go BFF middleware, Python retrieval tier, MCP PEP |
| [nats-subjects.md](./nats-subjects.md) | NATS subject schema | Go BFF ↔ Python workers |
| [mcp-tools.md](./mcp-tools.md) | 10 MCP tools across 4 categories (A–C read-only; D = HITL-gated `web_search` + `edit_note`) | LangGraph agent, local agents |
| [agent-graph.md](./agent-graph.md) | LangGraph agent internal contract — `AgentState`, node I/O, checkpointing, streaming, Phase-2 seams | Python agent tier (`services/agent/`) |
| [llm-gateway.md](./llm-gateway.md) | Standalone LLM gateway service (LiteLLM, Bifrost-swappable) + per-runtime client | All Go/Python LLM call sites |
| [metering-ports.md](./metering-ports.md) | Reusable `Meter`/`Pricer`/`Ledger` ports for the credit backbone (domain-agnostic) | Go kernel `metering`/`billing`, all spend producers |
| [notification-ports.md](./notification-ports.md) | Reusable `Notifier`/`Channel`/`Store` ports for the multi-channel notification backbone (domain-agnostic) | Go kernel `notify`, all notification producers |
| [approval-ports.md](./approval-ports.md) | Reusable `HumanGate`/`ApprovalStore` ports — the durable, fail-closed, no-spend-while-paused human-in-the-loop gate (`interrupt()`/resume seam) | Go kernel `approval`, Go BFF, Python agent + ingestion tiers |
| [sse-events.md](./sse-events.md) | SSE event taxonomy | Go BFF ↔ React SPA |

## Conventions

- **Auth**: browser sessions use **OIDC Authorization Code + PKCE** (Casdoor behind the kernel `Auth` interface), carried as an **opaque reference token** in an HttpOnly cookie and looked up in Redis (no claims on the wire, instantly revocable); local agents use a scoped device **PAT**. `workspace_id` and `Actor` are resolved server-side from the session; never trusted from the request body. Full flow: [auth-flow.md](./auth-flow.md).
- **Tenancy**: the Tenant middleware sets `SET LOCAL app.workspace_id` so RLS applies to every query in the request transaction.
- **Errors**: unified JSON error envelope `{ "error": { "code": string, "message": string, "details"?: object } }`. Codes are stable strings (e.g., `payment_required`, `limit_reached`, `unsupported_type`, `oversize`, `forbidden`, `not_found`, `injection_blocked`). Cross-clearance/cross-workspace resource lookups return `not_found` (never `forbidden`) so a higher-clearance resource's existence is not probeable (SC-001).
- **Idempotency**: any credit-affecting call accepts an `Idempotency-Key` header (or derives one); replays are no-ops (FR-019).
- **Request limits**: every BFF endpoint (including the OpenAI-wire-compatible `/llm/proxy` exposed to external agents) enforces a maximum request-body size at the edge/BFF; oversize requests are rejected with `413` before any downstream work (defense-in-depth against resource exhaustion).
- **Status codes**: `402` payment required (workspace balance exhausted), `429` daily/user limit reached, `413` oversize upload, `501` unsupported ingestion type (video/audio stub).
