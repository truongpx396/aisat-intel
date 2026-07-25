# Contract: LLM Gateway (standalone service + per-runtime client)

**Plan**: [../plan.md](../plan.md) | The single chokepoint for **all** LLM access. Phase 1 runs a **standalone, OpenAI-wire-compatible gateway service** — **LiteLLM** on `:4000`, **swappable with Bifrost** (Go-native) or Portkey by config (research §21) — that holds every provider key and owns alias resolution, multi-key load-balancing, and one-hop fallback. Both runtimes call it as an OpenAI endpoint via a **thin client** and make **no direct provider SDK calls**. The Python client (`services/llm_gateway.py`) and the Go `/llm/proxy` policy chain wrap the service with the app-specific concerns it must **not** own (clearance-scoped cache, PII scrub, spend emission, credit deduction).

## Model aliases & fallback

Business code references aliases only — never model IDs (FR-029). The alias→model map, the `{primary, fallback}` pairing, and multi-key/deployment load-balancing are **configured in the standalone gateway** (LiteLLM router config / Bifrost equivalent — `deploy/llm-gateway/*.yaml`), not in application code (research §4, §21).

| Alias | Primary | Fallback | Used for |
|-------|---------|----------|----------|
| `fast` | OpenAI GPT-4o-mini | Anthropic claude-haiku-4-5 | metadata extraction, image captioning, simple queries |
| `smart` | OpenAI GPT-4o | Anthropic claude-sonnet-4-6 | complex query generation |
| `embed` | OpenAI text-embedding-3-small | Voyage voyage-3-lite | embeddings — **no per-call fallback** (see caveat) |
| `rerank` | Cohere Rerank | local BGE-Reranker | cross-encoder reranking |

**Fallback rules**: fail over on timeout / 5xx / rate-limit only — never on "bad output". Cap at **one** hop. Emit `llm.fallback.count`; a circuit breaker trips back to primary when the primary error rate spikes. **Embedding caveat**: mixing embedding models within one Qdrant collection makes distances meaningless, so the `embed` alias is pinned single-model with **no fallback route** — a down primary embedder parks the chunk in `ingestion.dlq` for retry (FR-029).

## Deployment & swappability (LiteLLM ↔ Bifrost)

- The gateway is a **standalone service** (`llm-gateway:4000`) — its own deployment, the **only** holder of provider API keys, OpenAI-wire on `/v1/chat/completions` + `/v1/embeddings` (+ a rerank endpoint for the `rerank` alias).
- **Swap by config, no caller change**: `LLM_GATEWAY_KIND` (`litellm`|`bifrost`) + `LLM_GATEWAY_URL`; aliases/keys/LB routing live in `deploy/llm-gateway/*.yaml`. Both engines are OpenAI-wire, so Go and Python callers are identical across the swap.
- **The gateway's own budget/spend and response-cache features are DISABLED** — metering and caching stay in the app because they encode release-blocking invariants the gateway cannot model:
  - **Metering (SC-006)** — the gateway returns token usage only; cost is computed at the call site and the **Go kernel billing worker is the single `credit_ledger` writer** (via `billing.deduct.<ws>`). Spend is emitted **per-caller from returned usage — never via a gateway-specific callback** (e.g. LiteLLM's), so metering stays gateway-agnostic across the LiteLLM↔Bifrost swap. Never a second money system.
  - **Answer-cache (SC-001)** — the gateway's prompt+model cache is off; the semantic answer-cache lives in the Python query/agent path keyed by `workspace + clearance + authorized-doc-set`, so a higher-clearance answer can never be served to a lower-clearance member.
  - **Logging / PII (FR-024)** — the gateway's own tracer/body-logging (e.g. LiteLLM's Langfuse callback) is **off**; the app client wrapper is the **sole writer of prompt/response bodies, after PII scrub**, so the FR-024 scrub + 30-day-retention path stays authoritative and un-bypassed.
- **Tier-0 infra**: on the critical path, custodies keys — HA + scaling (autoscale on in-flight; multi-key LB is native to the gateway) are Phase 4.

## Interface

The **Python gateway-client** (`services/llm_gateway.py`) exposes this interface to business code and forwards to the standalone gateway over HTTP; it is also the swap seam (LiteLLM↔Bifrost is a client-config change, invisible to callers):

```python
@dataclass
class LLMRequest:
    model: str            # alias ("fast"/"smart") or exact name
    messages: list
    workspace_id: str
    user_id: str
    feature: str          # "ingest.metadata" | "ingest.caption" | "query.simple" | "query.complex"
    json_schema: dict | None = None
    max_tokens: int = 2048    # per-call output cap — third cost-defense layer (FR-017)
    stream: bool = False
    idem_key: str | None = None

@dataclass
class LLMResponse:
    content: str
    model: str            # resolved model name
    input_tokens: int
    output_tokens: int
    cost_usd_micros: int
    duration_ms: int
    cache_hit: bool

async def chat(req: LLMRequest) -> LLMResponse: ...
async def chat_stream(req: LLMRequest) -> AsyncIterator[str]: ...
async def embed(texts: list[str], workspace_id: str) -> list[list[float]]: ...
```

## Pipeline (every `chat` call)

**Python gateway-client** (per call): `idempotency check → budget check → clearance-scoped cache check → [forward to gateway :4000] → PII scrub → trace write → llm_call_log write → spend emit (billing.deduct) → idempotency record`
**Standalone gateway** (LiteLLM/Bifrost): `alias resolution → multi-key load-balance → provider call → one-hop fallback on timeout/5xx/429 → token counting`

The client owns idempotency, the clearance-cache, budget gating, PII scrub, and spend; the service owns alias/LB/fallback/provider I/O. For **external agents** the budget gate + credit deduct run in the Go `/llm/proxy` chain instead of the Python client (§20, §21).

- **Idempotency**: `idem_key = req.idem_key` when the caller supplies one (the only reliable retry signal); otherwise it falls back to `sha256(workspace_id | model | messages | json_schema)` scoped to a **short** window (`TTL 60s`, not 24h) so a genuine re-ask of the same question minutes later is **not** silently served the stale answer or skipped for billing. `GETSET llm:idem:{idem_key}`: hit → return stored response without calling provider or deducting credits; miss → proceed and store. The credit deduction is bound to the same `idem_key` (FR-019, SC-006). Dedup-for-latency on legitimate repeat questions is the semantic cache's job (below), keyed independently; the idempotency layer exists only to make a *retry* a no-op.
- **Budget check**: per-role daily token budget (Redis) + workspace balance; over-budget short-circuits before the provider call (FR-016/FR-017).
- **Semantic cache**: key = `sha256(workspace_id | user_id | effective_access_level | model | normalize(query))`; personal-knowledge answers per-user, workspace-only answers MAY share per `(workspace_id, access_level)` via `cacheable_scope` (research §2, SC-001).
- **PII scrub before write**: prompts/responses are PII-scrubbed before any Langfuse/eval write; raw bodies retained 30 days then purged (FR-024, Clarification Q5).
- **Logging**: `llm_call_log` gets metadata/token/cost only — never raw message bodies (FR-024).

## Cost settlement & stream cancellation

Both rules below exist because an LLM call has a **variable cost known only after it runs**, and a streamed call can be **abandoned mid-flight**. Phase 1 pins the policy so neither case leaks money silently.

- **Settlement is post-call; the budget check is an admission gate, not a reservation.** The pipeline's *budget check* reads the current workspace balance + per-role daily token budget and refuses a call already at/over limit — it does **not** pre-debit. When the provider returns (or a stream ends/aborts) the **caller** (the Python gateway-client, or the Go `/llm/proxy` chain) reads the standalone gateway's returned `input_tokens + output_tokens`, computes `cost_usd_micros`, and publishes `billing.deduct.<ws>` bound to the call's `idem_key`; the Go kernel billing worker performs the Redis `DECRBY` + ledger write (research §3, §21). Cost is emitted **per-caller from returned usage — never via a gateway-specific callback** (keeps the LiteLLM↔Bifrost swap off the money path). Python never touches the balance.
- **Concurrency overshoot is bounded, and Phase 1 accepts it.** Because admission is a gate and settlement is post-call, K calls admitted concurrently against a near-empty balance can settle it slightly negative. The overshoot is **bounded** — each in-flight call's cost is capped by the per-call output cap (`max_tokens`, FR-017) plus the body-size-limited input (the BFF `413` guard), so worst case ≈ *in-flight concurrency × per-call ceiling*. Phase 1 **accepts this bounded overshoot and heals it at settlement and the hourly reconcile** (SC-006) rather than paying the latency of a hard two-phase reserve-then-refund. Exact pre-authorization of a variable cost would require either serializing a workspace's calls (kills throughput) or reserving `max_tokens` on every call and refunding the remainder (doubles ledger writes); gate + bounded-overshoot + reconcile is the standard token-metering posture. A hard per-call reservation is a **Phase 4** option, warranted only if a workspace's `concurrency × cap` becomes a material fraction of a typical balance.
- **Stream cancellation propagates end-to-end, and a cancelled stream settles for what it generated.** A `chat_stream` whose consumer goes away MUST abort the whole chain: the Go `/llm/proxy` handler's request context cancels on client disconnect → cancels the forwarded HTTP request to the gateway (`:4000`) → the gateway aborts the provider SDK stream. No generation continues server-side after the client is gone. A cancelled/aborted stream is **still billed for the tokens actually emitted before the abort** — not zero (which would make "open a stream, disconnect" a free-inference abuse vector) and not the full `max_tokens` (which would over-bill an early cancel). The caller counts partial `output_tokens` from the relayed stream, publishes the `billing.deduct` for that partial cost under the same `idem_key`, and records the call in the trace + `llm_call_log` as `cancelled` with the partial counts. Cancellation on **byok** is the agent's own provider concern; this obligation covers the metered `proxy` path.

## External agent integration note

`/llm/proxy` (Go BFF) is the external entrypoint for this gateway. It is OpenAI-wire-compatible so external agents (Cursor, Claude Code, Cline, etc.) can point their `LLM_BASE_URL` at it without code changes. After the Go policy chain (PAT auth, budget gate, credit deduct), `/llm/proxy` forwards to the **standalone gateway** (`:4000`) — not the Python tier (§20).

Both `proxy` and `byok` modes must configure the MCP server to access the knowledge base. The difference is only on the LLM side:

| Mode | Shown to members as | LLM calls | MCP tool calls | Moderation | Metering |
|------|---------------------|-----------|----------------|------------|----------|
| **proxy** (default) | *"Use the AISAT gateway"* | `POST /llm/proxy` → this gateway | MCP server `:8002` (server-side, always) | ✅ Node 0 | ✅ credits |
| **byok** | *"Use your own AI provider"* | direct to provider (bypasses gateway) | MCP server `:8002` (server-side, always) | ❌ skipped | ❌ |

`proxy` / `byok` are the config identifiers; the middle column is the wording every UI surface
uses. Do not surface the identifiers to members — the choice is framed as a convenience
(`proxy` means *no API key to obtain or manage*), not as a governance setting. Full copy
guidance: [design-system agents page](../../../design-system/aisat-intel/pages/agents.md).

**Two modes only, no third.** An agent whose vendor runs its own inference (GitHub Copilot and
similar, with no endpoint to redirect) is simply `byok` — it reaches the MCP server and never
calls `/llm/proxy`. It needs no separate mode: every behaviour above is already identical.

**Key invariant**: MCP tool calls are always routed server-side regardless of LLM mode (`research.md §5`). A BYOK agent still gets `allowed_tools` enforcement, RLS-scoped knowledge access, and audit logging — it only loses LLM-level moderation and credit metering. Admins can disable BYOK per workspace.

Configuring only `/llm/proxy` without the MCP server gives governance and metering but **no RAG or knowledge-base access**. To get the same capability as the built-in LangGraph chat, an external agent must configure both.

## Transport (Go BFF ↔ gateway)

The `/llm/proxy` hop is a **synchronous HTTP streaming pass-through** — not gRPC, not NATS (research §20). The Go BFF (`:8080`) runs the policy chain, then forwards the OpenAI-shaped request to the **standalone LLM gateway** (`:4000`, LiteLLM/Bifrost) over HTTP/1.1, relaying a `stream:true` response **verbatim as SSE** (`text/event-stream`, flush-per-chunk, no buffering). Client disconnect cancels `request.Context()` → the forwarded HTTP request → the gateway stream → the provider SDK stream (see "Cost settlement & stream cancellation" above). This is the **only** synchronous Go→gateway call; the Python tier calls the same gateway directly for ingest/agent, and all Go↔Python traffic is async over NATS JetStream. Keeping HTTP+SSE end-to-end lets Go be a thin reverse-proxy that never re-serializes the OpenAI-wire payload; gRPC is rejected because it would add a JSON↔protobuf↔SSE translation on both edges for a text-token stream and would break the LiteLLM↔Bifrost OpenAI-wire swap (research §20, §21).

## Contract test obligations

- A repeated `chat` carrying the same explicit `idem_key` (a retry) calls the provider once and deducts credits once (SC-006); a genuine re-ask of an identical question after the 60s content-hash window is treated as a fresh call (provider invoked, credits deducted), not silently deduplicated.
- A primary-provider timeout fails over exactly once and increments `llm.fallback.count`; a low-quality (but successful) response does **not** fail over (FR-029).
- `embed` never silently substitutes the fallback model for a live call; the affected item is parked in DLQ (FR-029).
- A prompt containing an email/token is PII-scrubbed before it appears in any trace/eval store (FR-024).
- Concurrent calls that each pass the budget gate but jointly exceed the balance settle to a **bounded-negative** balance (no worse than `−(in-flight concurrency × per-call ceiling)`), and the next hourly reconcile restores it to ledger truth (SC-006) — settlement is never skipped because the balance went to/below zero mid-flight.
- A `chat_stream` whose client disconnects mid-stream **cancels the provider call** (the trace records no `output_tokens` produced after the disconnect timestamp) and deducts credits for **exactly the tokens emitted before cancel** — never zero, never the full `max_tokens` — under the call's `idem_key`.
- A streaming `/llm/proxy` call relays the gateway's provider SSE frames **unbuffered** (flush-per-chunk, transport is HTTP streaming — never gRPC/NATS), and a client disconnect propagates as an HTTP request-context cancellation to the standalone gateway (`:4000`) within the same request (research §20, §21).

---

## Phase 2 (out of scope here)

> Out of Phase 1 scope (see [spec.md](../spec.md) "Out of Scope"); designed in
> [draft-plan.md — Agent Access & Accountability](../../draft-plan.md#phase-2--agent-access--accountability).
>
> **Routing is verified, not trusted.** Phase 1 records the mode an agent declared at
> registration. Phase 2 continuously compares that declaration against observed traffic — this
> gateway already knows whether calls arrive for a given agent credential — and surfaces a
> mismatch. The failure it catches is an agent registered as `proxy` whose calls never arrive
> (most often a provider key still exported in its environment, which takes precedence over
> `LLM_BASE_URL`): no credits are spent, nothing is moderated, and every screen still reports
> the agent as metered. Treated as onboarding help, not enforcement.
