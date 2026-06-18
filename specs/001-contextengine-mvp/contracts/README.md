# Contracts: AISAT-STUDIO MVP (Phase 1)

**Date**: 2026-06-06 | **Plan**: [../plan.md](../plan.md)

These contracts define the external/internal interfaces the system exposes. They are the test targets for contract + integration tests (constitution Principle II) and the source of truth for the boundaries between the Go BFF, the Python ML tier, the MCP tool surface, and the React SPA.

## Files

| Contract | Surface | Consumers |
|----------|---------|-----------|
| [bff-rest.md](./bff-rest.md) | Go BFF public REST + SSE endpoints | React SPA, local agents |
| [nats-subjects.md](./nats-subjects.md) | NATS subject schema | Go BFF ↔ Python workers |
| [mcp-tools.md](./mcp-tools.md) | 9 MCP tools across 3 categories | LangGraph agent, local agents |
| [llm-gateway.md](./llm-gateway.md) | Python LLM gateway interface | All Python LLM call sites |
| [sse-events.md](./sse-events.md) | SSE event taxonomy | Go BFF ↔ React SPA |

## Conventions

- **Auth**: every BFF request carries a JWT (browser) or device PAT (local agent). `workspace_id` and `Actor` are resolved server-side; never trusted from the request body.
- **Tenancy**: the Tenant middleware sets `SET LOCAL app.workspace_id` so RLS applies to every query in the request transaction.
- **Errors**: unified JSON error envelope `{ "error": { "code": string, "message": string, "details"?: object } }`. Codes are stable strings (e.g., `payment_required`, `limit_reached`, `unsupported_type`, `oversize`, `forbidden`, `not_found`, `injection_blocked`). Cross-clearance/cross-workspace resource lookups return `not_found` (never `forbidden`) so a higher-clearance resource's existence is not probeable (SC-001).
- **Idempotency**: any credit-affecting call accepts an `Idempotency-Key` header (or derives one); replays are no-ops (FR-019).
- **Request limits**: every BFF endpoint (including the OpenAI-wire-compatible `/llm/proxy` exposed to external agents) enforces a maximum request-body size at the edge/BFF; oversize requests are rejected with `413` before any downstream work (defense-in-depth against resource exhaustion).
- **Status codes**: `402` payment required (workspace balance exhausted), `429` daily/user limit reached, `413` oversize upload, `501` unsupported ingestion type (video/audio stub).
