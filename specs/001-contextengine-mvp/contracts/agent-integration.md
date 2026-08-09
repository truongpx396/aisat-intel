# Contract: Agent Integration — how AISAT satisfies `intel-agent`

**Runtime**: [truongpx396/intel-agent](https://github.com/truongpx396/intel-agent) | **Their side of the seam**: [host-integration.md](https://github.com/truongpx396/intel-agent/blob/main/specs/001-agent-runtime/contracts/host-integration.md) · [agent-deps.md](https://github.com/truongpx396/intel-agent/blob/main/specs/001-agent-runtime/contracts/agent-deps.md) | **Status**: the AISAT-side mirror of the host contract.

The agent runtime was extracted from this repo at [`369756e`](https://github.com/truongpx396/aisat-intel/commit/369756e) (tag `extraction-baseline-intel-agent`). AISAT is now its **reference Profile-A host**: it consumes the runtime as a pinned dependency and supplies the implementations and obligations the runtime declares but does not implement.

## Pinned version

```toml
# backend-python/pyproject.toml
dependencies = ["intel-agent @ git+https://github.com/truongpx396/intel-agent@v0.1.0"]
```

A port-protocol change upstream is **breaking for this repo**. It lands there first, bumps at least the minor version, and this repo's PR consumes it in a **separate** merge window.

## The organizing rule

> **intel-agent owns the port and ships a minimal default. AISAT overrides with its production implementation.**

Every ownership question at this seam resolves with that sentence. It is why `mcp-tools.md` moved but the tool bodies stayed, and why `approval-ports.md` moved but `approval_request` stayed.

**Refined since the extraction.** `intel-agent` is a **standalone product**, not a library. Every port has a **working default** — it ingests, authenticates, meters, moderates, and answers on its own. AISAT overrides each one because *its* version is the right one **for AISAT**, not because upstream ships placeholders:

| Port | intel-agent default (works) | AISAT binds instead | Why we override |
|---|---|---|---|
| `Ingestor` | files / URLs / text | conversion, captioning, crawling, sandboxed parsing | our corpus needs formats and isolation the default doesn't cover |
| `IdentityBinder` | single-user or user list | Casdoor OIDC + device PATs | we have real auth and multi-tenancy |
| `Meter` | real local usage ledger | the Go kernel billing worker | the `credit_ledger` must have exactly one writer (SC-006), and it is ours |
| `RetrievalService` | pgvector / sqlite | Qdrant hybrid + payload pre-filter | we need hybrid search at our scale |
| moderation | gateway moderation endpoint | our bound provider | policy and provider are ours to choose |
| UI | minimal built-in chat | the React SPA | product surface |

**Overriding is an upgrade, not a rescue.** A default is not privileged code — it passes the same conformance suite our override must. And per upstream's AR-035 there are **no hollow defaults**: a capability that cannot work without host context fails to start rather than silently passing.

So the practical rule is simply: **bind deliberately, and say why.** Not because inheriting is dangerous, but because a reviewer should be able to see which capabilities we replaced and which we accepted.

## Satisfying the five host obligations

| | Obligation | How AISAT satisfies it | Verified by |
|---|---|---|---|
| **H1** | Stamp `ctx` in a trusted layer | The Go BFF binds `tenant`/`principal` from the **verified session**, and `claims.effective_access_level` from the clearance ladder, into the NATS payload. Never from a request body. | **No suite can check this** — see below |
| **H2** | Enforce the access floor below the agent | Postgres RLS GUCs (`app.workspace_id`/`app.user_id`/`app.clearance`) set by the tenant middleware, **plus** the Qdrant payload pre-filter. Two lowerings of one predicate. | `AccessFloorContract` + SC-001 suite |
| **H3** | Meter and settle spend | The Go kernel billing worker is the **sole `credit_ledger` writer** (SC-006). The runtime emits `billing.deduct.<ws>` with an `idem_key`; the worker rejects duplicates. | `MeterContract` |
| **H4** | Provide moderation behind `guard` | The moderation provider is bound at the Python tier's composition root; fail-closed on timeout. | Guard fail-closed test (SC-007) |
| **H5** | Persist and resolve human gates | The kernel `approval_request` table, RLS-scoped to its approver, bound to the `ApprovalStore` port. | `ApprovalContract` (SC-014) |

### H1 is the one with no test

`AccessFloorContract` proves the floor *given* a `ctx`. It cannot prove the `ctx` was honestly stamped — the runtime has no way to distinguish a trustworthy `tenant` from a forged one, which is exactly why stamping it is the host's job.

So the guarantee for H1 is **code review of the BFF's stamping path**, not a suite. Treat any change to how `ctx` is populated as security-relevant, regardless of how mechanical the diff looks.

## What AISAT provides per port

| Port | AISAT implementation |
|---|---|
| `RetrievalService` | Qdrant hybrid (BM25/SPLADE + dense) with payload pre-filter, `retrieval.kind: qdrant` |
| `ToolRegistry` | The 10-tool catalog as this repo's `DomainPlugin`, `tools.kind: inprocess`; the FastMCP server exposes the same impls outward |
| `Policy` | `SingleAxisPolicy` (the 1–5 clearance ladder) |
| `LLMGatewayClient` | Thin client → the standalone LiteLLM gateway |
| `MemoryService` | Mem0, workspace/user-stamped |
| `StreamWriter` | Redis pub/sub adapter → Go SSE relay → browser |
| `Checkpointer` | `RedisSaver` (AOF) |
| `Bus` | `jetstream` |
| `Meter` | Emits to `billing.deduct.<ws>`; the Go worker owns the ledger |
| `Recorder` | `agent_audit_log` with the per-tenant hash chain |
| `ApprovalStore` | The kernel `approval_request` table |
| `Ingestor` | The full pipeline — presign, convert, caption, crawl, chunk, embed, index (**overrides** upstream's minimal default) |
| `IdentityBinder` | Casdoor OIDC sessions + device PATs (**overrides** upstream's single-user default) |

## Conformance in this repo's CI

```python
# backend-python/tests/contract/test_intel_agent_conformance.py
from intel_agent.conformance import (
    RetrievalServiceContract, ToolRegistryContract, PolicyContract,
    MeterContract, ApprovalContract, AccessFloorContract,
)

class TestQdrantRetrieval(RetrievalServiceContract):
    impl = QdrantHybridRetrieval

class TestSingleAxisPolicy(PolicyContract):
    impl = SingleAxisPolicy

class TestAisatAccessFloor(AccessFloorContract):
    impl, policy = QdrantHybridRetrieval, SingleAxisPolicy
```

These are what make contract drift a **build failure** rather than something a reviewer might notice. If they are red, the integration is broken even when the product appears to work.

## Testing AISAT without a live agent

The obvious worry after the extraction — *"our transport, debug panel, chat UI, and billing path have no agent to drive them"* — is answered by an export, not by a mock written here.

```python
from intel_agent.testing import FakeAgentRuntime, scenarios

graph = FakeAgentRuntime(scenarios.GATE_PAUSE_RESUME)   # no model, no Qdrant, no NATS
async for ev in graph.astream_events({"query": q, "ctx": ctx}):
    ...   # drive the SSE relay, the debug panel, the credit path
```

Scenarios: `CITED_ANSWER`, `REFUSAL`, `CLARIFICATION`, `GATE_PAUSE_RESUME`, `DEGRADED_RERANK`, `DEADLINE_DEFERRAL`, `ERROR`.

**Do not hand-roll a mock agent in this repo.** The double is versioned upstream alongside the event vocabulary it emits; a local one would be a second, unversioned definition of that vocabulary and would drift the moment the runtime adds an event — silently, because both sides would still be green. Upstream also ships **golden JSONL fixtures**, so this repo's transport tests and the runtime's own tests assert against the *same files*.

The relevant contract is [stream-events.md](https://github.com/truongpx396/intel-agent/blob/main/specs/001-agent-runtime/contracts/stream-events.md), which also fixes the ownership line:

| | Owner |
|---|---|
| Event **vocabulary** — what events exist, payload shape, ordering | **intel-agent** |
| Wire **framing** — SSE event names, retry, heartbeat, reconnect, HTTP status | **AISAT** (this repo, [sse-events.md](./sse-events.md)) |

This repo may rename an event on the wire; it may not invent a semantic event the runtime never emits, or silently drop one it does. `StreamEventContract` is what checks that, and it runs in **this** repo's CI against **this** repo's relay.

> **The bug this is designed to catch:** a paused run emits `gate_opened` and then **nothing** until resolved. It is *paused*, not finished. A relay that treats stream silence as completion will close the SSE connection and strand the approval — green tests, broken product. `GATE_PAUSE_RESUME` exists specifically to fail on that.

## Where the split is thinnest

Four upstream tasks are genuinely split — the runtime owns the emission, this repo owns the surface — so both repos carry half. These are the most likely places for a gap to hide, and are worth explicit attention at integration time:

| Task | Runtime side | AISAT side |
|---|---|---|
| T069 | — | semantic answer cache (host hot path) |
| T074 | prompt assets ship upstream | authored against this repo's response format |
| T075 | graph entrypoint + stream events | query router, Redis stream adapter, SSE transport |
| T101/T101b | per-node debug **fragments** | debug-panel assembly and streaming to the SPA |

## Deprecated in this repo

[agent-graph.md](./agent-graph.md), [agent-runtime.md](./agent-runtime.md), [mcp-tools.md](./mcp-tools.md), and [approval-ports.md](./approval-ports.md) are pointer stubs. Their content, and their full commit history, live upstream.
