# Contracts: AISAT-INTEL MVP (Phase 1)

**Date**: 2026-06-06 | **Plan**: [../plan.md](../plan.md)

These contracts define the external/internal interfaces the system exposes. They are the test targets for contract + integration tests (constitution Principle II) and the source of truth for the boundaries between the Go BFF, the Python ML tier, the MCP tool surface, and the React SPA.

> ## The agent runtime now lives in its own repo
>
> As of [`369756e`](https://github.com/truongpx396/aisat-intel/commit/369756e) (tag `extraction-baseline-intel-agent`), the agent runtime was extracted to **[truongpx396/intel-agent](https://github.com/truongpx396/intel-agent)** and is consumed here as a pinned dependency. AISAT is its reference **Profile-A** host.
>
> **The rule that resolves every ownership question at the seam:** *intel-agent owns the **port**; AISAT owns the **implementation** and the **deployment**.*
>
> - **[agent-integration.md](./agent-integration.md)** — start here. How AISAT satisfies the runtime's five host obligations, which version is pinned, and where the conformance suites run.
> - `agent-graph.md`, `agent-runtime.md`, `mcp-tools.md`, `approval-ports.md` are now **pointer stubs**. Their content and full commit history live upstream.
>
> Two things deliberately did **not** move, and both are instances of the rule above: the **tool bodies** (domain code — this repo's `DomainPlugin`) and the **`approval_request` table** (a kernel table that also backs the ingestion `enrich_accept`/`sensitivity_confirm` gates).

## Files

| Contract | Surface | Consumers |
|----------|---------|-----------|
| [bff-rest.md](./bff-rest.md) | Go BFF public REST + SSE endpoints | React SPA, local agents |
| [auth-flow.md](./auth-flow.md) | Browser OIDC (PKCE) + device PAT auth sequences | React SPA, local agents |
| [authorizer-ports.md](./authorizer-ports.md) | Reusable `Authorizer`/`Policy`/`Lowerer` ports — one predicate lowered to RLS **and** Qdrant (parity), the swappable access-model seam | Go BFF middleware, Python retrieval tier, MCP PEP |
| [nats-subjects.md](./nats-subjects.md) | NATS subject schema | Go BFF ↔ Python workers |
| [agent-integration.md](./agent-integration.md) | **How AISAT satisfies the extracted runtime's host contract** — the pinned `intel-agent` version, the five host obligations and how each is met, the per-port implementation map, and where the conformance suites run | Go BFF, Python agent tier, CI |
| [mcp-tools.md](./mcp-tools.md) | ⤴ **moved** to intel-agent (stub). The `ToolRegistry` port and dispatch wrapper are upstream; this repo owns the **tool bodies** as its `DomainPlugin` | LangGraph agent, local agents |
| [agent-graph.md](./agent-graph.md) | ⤴ **moved** to intel-agent (stub) — `AgentState`, node I/O, checkpointing, streaming, reliability, run budgets, telemetry | Python agent tier |
| [agent-runtime.md](./agent-runtime.md) | ⤴ **moved** to intel-agent (stub) — `AgentManifest` + `DomainPlugin` composition, swap matrix, Profiles A/B. AISAT is the reference Profile-A host | Python agent tier, Go kernel `authz`, app-root DI |
| [llm-gateway.md](./llm-gateway.md) | Standalone LLM gateway service (LiteLLM, Bifrost-swappable) + per-runtime client | All Go/Python LLM call sites |
| [sandbox-runtime.md](./sandbox-runtime.md) | Standalone sandbox tier (hardened pod in Phase 1; gVisor/Firecracker-microVM swappable) + `Sandbox` port — the single chokepoint for isolated code/tool exec (crawl4ai, MarkItDown convert, code-gen) | Python crawl/ingest/agent tiers |
| [metering-ports.md](./metering-ports.md) | Reusable `Meter`/`Pricer`/`Ledger` ports for the credit backbone (domain-agnostic) | Go kernel `metering`/`billing`, all spend producers |
| [notification-ports.md](./notification-ports.md) | Reusable `Notifier`/`Channel`/`Store` ports for the multi-channel notification backbone (domain-agnostic) | Go kernel `notify`, all notification producers |
| [approval-ports.md](./approval-ports.md) | ⤴ **moved** to intel-agent (stub). The `HumanGate`/`ApprovalStore` **ports** are upstream; the **`approval_request` table stays here** — it also backs the ingestion `enrich_accept`/`sensitivity_confirm` gates | Go kernel `approval`, Go BFF, Python agent + ingestion tiers |
| [audit-ports.md](./audit-ports.md) | Reusable `Recorder`/`Sink`/`HashChain` ports — the append-only, tamper-evident, tenant-scoped audit backbone (domain-agnostic; unifies `audit_log` + `agent_audit_log` behind one opaque `Actor`/`Tenant`) | Go kernel `audit`, all audit producers (auth/billing/invite/agent/admin/approval/sandbox) |
| [sse-events.md](./sse-events.md) | SSE event taxonomy | Go BFF ↔ React SPA |
| [credits-ui-ports.md](./credits-ui-ports.md) | Reusable `CreditsSource`/`LimitView`/`LedgerColumn` ports — the props-only balance, ceilings, breakdown and ledger surface (domain-agnostic; AISAT's `credits` unit and LLM ledger columns are injected, not built in). The UI half of [metering-ports.md](./metering-ports.md) | React SPA (`frontend/src/credits-ui/`), Go BFF `GET /credits` |
| [stream-ui-ports.md](./stream-ui-ports.md) | Reusable `StreamRenderer`/`StreamSource`/`TraceSection` ports — the props-only, app-dep-free chat + trace-inspector kernel (domain-agnostic; AISAT's RAG retrieval trace is one registered `rag_retrieval` renderer, not the panel's schema) | React SPA (`frontend/src/stream-ui/`), Go BFF debug endpoint |

## Conventions

- **Auth**: browser sessions use **OIDC Authorization Code + PKCE** (Casdoor behind the kernel `Auth` interface), carried as an **opaque reference token** in an HttpOnly cookie and looked up in Redis (no claims on the wire, instantly revocable); local agents use a scoped device **PAT**. `workspace_id` and `Actor` are resolved server-side from the session; never trusted from the request body. Full flow: [auth-flow.md](./auth-flow.md).
- **Tenancy**: the Tenant middleware sets `SET LOCAL app.workspace_id` so RLS applies to every query in the request transaction.
- **Errors**: unified JSON error envelope `{ "error": { "code": string, "message": string, "details"?: object } }`. Codes are stable strings (e.g., `payment_required`, `limit_reached`, `unsupported_type`, `oversize`, `forbidden`, `not_found`, `injection_blocked`). Cross-clearance/cross-workspace resource lookups return `not_found` (never `forbidden`) so a higher-clearance resource's existence is not probeable (SC-001).
- **Idempotency**: any credit-affecting call accepts an `Idempotency-Key` header (or derives one); replays are no-ops (FR-019).
- **Request limits**: every BFF endpoint (including the OpenAI-wire-compatible `/llm/proxy` exposed to external agents) enforces a maximum request-body size at the edge/BFF; oversize requests are rejected with `413` before any downstream work (defense-in-depth against resource exhaustion).
- **Status codes**: `402` payment required (workspace balance exhausted), `429` daily/user limit reached, `413` oversize upload, `501` unsupported ingestion type (video/audio stub).
