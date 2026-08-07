# Contract: SSE Event Taxonomy

**Plan**: [../plan.md](../plan.md) | The streaming contract between the Go BFF and the React SPA (`frontend/src/lib/sse.ts`). The BFF relays Python worker output (via Redis pub/sub keyed by `stream_id`) as Server-Sent Events.

> **Relay is a separable tier (locked in Phase 1, research §14).** The SSE relay subscribes to Redis pub/sub by `stream_id` and forwards only — it holds no request-handling logic. Phase 1 MAY co-deploy it with the request-handling BFF, but the clean boundary lets Phase 4 split it into an independently connection-scaled tier without touching handlers.

> **Why Redis pub/sub, not JetStream, for the streaming hop.** Work dispatch (BFF→worker) uses JetStream because a job must be durable, redeliverable, and lag-measurable. The live-token hop (worker→relay→browser) is ephemeral fan-out to an already-connected client, so it uses Redis pub/sub keyed by `stream_id`: lowest latency, trivial per-stream fan-out, fire-and-forget. A dropped token is cosmetic — credits, audit, and the final answer/citations are authoritative in Postgres, not the stream. JetStream here would add per-token persistence and per-query consumer churn for no benefit. Replay-on-reconnect (not a Phase 1 requirement) would be a **Redis Stream** (`XADD`/`XREAD`), still not JetStream.
>
> **Scaling caveat (Phase 4, do not defer the decision).** Classic Redis `PUBLISH`/`SUBSCRIBE` is **broadcast across the entire cluster bus** under Redis Cluster — every node receives every message regardless of which relay replica needs it. So the moment Redis moves to Cluster for HA, the streaming hop MUST switch to **sharded pub/sub** (`SPUBLISH`/`SSUBSCRIBE`, Redis 7+) keyed by a **slot-hash-tagged `stream_id`** (`{stream}:<id>`), so a token reaches only the relay replicas on that stream's shard. This makes the separable-relay decision (above) and the Redis-Cluster move a **single coupled workstream, not two independent phases** — tracked jointly in [research §10](../research.md) and [draft-plan Phase 4 items 2 + 6](../../draft-plan.md#6-redis-high-availability). It is a config/keying change (no event-taxonomy change), because any relay replica already serves any `stream_id` with no sticky sessions.

> **Why our own named-event taxonomy, not a vendor wire (OpenAI or Anthropic) verbatim.** Two streaming hops exist and answer differently. The **worker↔LLM-gateway** hop stays on the **OpenAI wire** (LiteLLM normalizes every provider — including Claude — to OpenAI chat-completion chunks that LangGraph's `astream_events` consumes; [agent-graph.md](./agent-graph.md) Streaming). The **relay↔browser** hop below is a **product contract**, so it is domain-owned. We deliberately borrow Anthropic's *pattern* — discrete, typed, named lifecycle events — because it renders far better than OpenAI's single `delta`-chunk envelope for a UI that must show retrieval stages, tool calls, sub-agent activity, HITL gates, and citations. We do **not** adopt Claude's *schema* (`message_start`/`content_block_delta`/`content_block_stop`/`message_delta`/`message_stop` with per-block `index`): naming events after Anthropic's blocks would couple our own wire to a schema Anthropic controls, buy zero SDK compatibility (the SPA reads our relay, not the Anthropic API), and force our domain events (`status`, `approval_request`, `suggestions`, `notification`, `agent_step`) into a block model they don't fit. Swapping the model behind the gateway must never change this hop — that is the whole point of the relay boundary. The one genuinely useful idea from Claude's format we *do* take is a **keepalive `ping`** (below).

## Event types

```typescript
type SSEEventType =
  | { event: "token";       data: { content: string } }
  | { event: "thinking";    data: { content: string } }              // model reasoning surface (opt-in display)
  | { event: "agent_step";  data: AgentStep }                        // node / sub-agent / skill / planner lifecycle beat (see Agentic activity)
  | { event: "tool_use";    data: ToolUse }                          // a tool call started (correlated by id, nestable by parent_id)
  | { event: "tool_result"; data: ToolResult }                       // that tool call finished (pairs to tool_use.id; carries ok/error)
  | { event: "status";      data: { stage: string } }               // coarse run stage; the agent_step stream is the fine-grained view
  | { event: "ping";        data: { t: number } }                    // keepalive heartbeat on idle long-lived streams; client MUST ignore
  | { event: "error";       data: { code: string; message: string } }
  | { event: "done";        data: { usage: { input: number; output: number }; credits_deducted: number } }
  | { event: "suggestions"; data: { questions: string[] } }  // FR-031: 2–3 follow-up chips, only when source_count > 0 and answer was not refused
  | { event: "clarification"; data: Clarification }          // FR-045: the turn ENDS by asking which reading was meant (never a pause)
  | { event: "trace_section"; data: TraceSection }           // FR-021: a debug section, streamed as its stage completes
  | { event: "approval_request"; data: ApprovalRequest }      // FR-040: a durable run paused for a human decision (HITL)
  | { event: "notification";  data: Notification }            // FR-034: a new notification for the connected recipient
  | { event: "unread_count";  data: { unread: number } }      // FR-034: updated bell badge count
```

```typescript
// A hierarchical activity beat — the live, browser-facing analogue of the run-record `trace[]`
// (the same node/sub-agent/skill lineage, streamed instead of persisted). This is the extensible
// envelope that keeps the wire agentic-ready: a MORE agentic hosted agent (a domain MCP agent, a
// planner that spawns sub-agents, a skill-driven runtime) streams through the SAME taxonomy — new
// activity is a new `kind`, NEVER a new event type, so it is additive with no wire break (mirrors
// the graph's "additive node, no refactor" rule, agent-graph.md).
interface AgentStep {
  id: string;                 // correlates the phase:"start" beat with its phase:"end"; also the parent_id children reference
  parent_id: string | null;   // nesting handle: a tool/skill under a sub-agent, a sub-agent under the root run; null = top level
  kind: "node" | "subagent" | "skill" | "planner";  // extend ADDITIVELY; an unknown kind renders as a generic collapsible row
  phase: "start" | "end";
  label: string;              // human-readable, e.g. "retrieve", "web-research subagent", "systematic-debugging"
  status?: "ok" | "error" | "degraded";   // present on phase:"end" only (a degraded node still ended, e.g. rerank→RRF)
  detail?: Record<string, unknown>;        // kind-specific UI hint ONLY — never an access decision, never authoritative
}

interface ToolUse {
  id: string;                 // correlation handle; the matching tool_result echoes it (enables parallel/interleaved calls)
  parent_id: string | null;   // the agent_step (node or sub-agent) this call belongs under
  name: string;               // stable tool identifier, e.g. "web_search", "get_document_by_id"
  title?: string;             // display label, e.g. "Searching the web"
  input: unknown;             // server-side REDACTED before emission — never carries secrets/PII/raw credentials
}

interface ToolResult {
  id: string;                 // pairs to the originating tool_use.id
  name: string;
  status: "ok" | "error";     // a failed tool renders distinctly instead of inferring failure from output text
  output: string;             // human-safe summary; large payloads truncated server-side (the authoritative result lives in Postgres/audit)
  duration_ms?: number;
}
```

```typescript
interface Notification {
  id: string;
  category:
    | "ingestion_complete" | "ingestion_failed"
    | "invite_received" | "invite_accepted" | "invite_revoked"
    | "credit_warning" | "credit_exhausted" | "task_halted" | "approval_requested"
    | "doc_shared" | "clearance_changed" | "member_joined" | "admin_broadcast";
  priority: "info" | "warning" | "critical";
  title: string;
  body: string;
  payload: Record<string, unknown>;  // deep-link refs, e.g. { doc_id }, { invite_id }, { run_id }
  read_at: string | null;
  created_at: string;
}

// FR-045 — the agent asks which reading was meant. NOT an approval and NOT a pause: this event
// IS the turn's response. `done` follows immediately; no run is held open, no credits are held
// pending, and the member's choice arrives as a NORMAL follow-up POST /query. That is what keeps
// the "interactive queries never pause" invariant true while still letting the agent ask.
interface Clarification {
  id: string;                  // echoed back on the follow-up query, so eval can measure whether asking helped
  question: string;            // "Which Q3 did you mean?" — one line, never a paragraph
  options: ClarificationOption[];   // 2–4. Fewer than 2 is not a choice; more than 4 is a menu, not a clarification
  allow_custom: true;          // ALWAYS true — a member is never trapped in a menu that omits what they meant
}

interface ClarificationOption {
  id: string;                  // stable within this clarification
  label: string;               // short chip text, e.g. "Q3 FY26 actuals"
  detail?: string;             // one-line disambiguator, e.g. "board deck, Oct 2026"
}

interface ApprovalRequest {           // FR-040 — a human-in-the-loop gate awaiting the connected member
  id: string;
  kind: "enrich_accept" | "long_horizon_action" | "sensitivity_confirm" | "web_search" | "note_edit";  // FR-040/FR-041
  subject_ref: Record<string, unknown>;  // what is gated: { note_id } | { run_id, step } | { doc_id }
  prompt: string;                     // human-readable "what am I approving?"
  payload: Record<string, unknown>;   // detail for the UI: { suggested_level } | draft ref | step description
  expires_at: string | null;          // fail-closed deadline; null = no expiry
}
```

## Agentic activity (tools, sub-agents, skills)

The agent's work is exposed to the browser as a **hierarchy of `agent_step` beats plus correlated `tool_use`/`tool_result` pairs** — the live analogue of the persisted run-record `trace[]`. This is the model that makes the wire render an agentic run (nested tool calls, sub-agent fan-out, skill activations) instead of a flat token dribble.

**Correlation & nesting.** Every activity carries an `id`; children reference it via `parent_id` (`null` = top level). A `tool_use` opens with an `id` and its `tool_result` echoes the same `id`, so **parallel/interleaved** tool calls pair unambiguously. An `agent_step` opens with `phase:"start"` and closes with `phase:"end"` (+ terminal `status`) under the same `id`. The client builds the tree purely from `id`/`parent_id` — the relay never needs ordered delivery per branch, only per-`id` start-before-end.

**One shape for all agentic activity — additive, never a wire break.** Rather than minting a new event type per capability (`subagent_start`, `skill_call`, `planner_step`, …), all lifecycle activity is one `agent_step` discriminated by `kind`. A more agentic *hosted* agent — a domain MCP agent, a planner that spawns sub-agents, a skill-driven runtime — streams through the **same** taxonomy: a new capability is a new `kind` value, so the SPA's typed client keeps compiling and unknown kinds degrade to a generic collapsible row. This mirrors the graph's "additive node, no refactor" guarantee ([agent-graph.md](./agent-graph.md)) and the run-record's own `subagent` trace.

| `kind` | Emitted by (Phase 1) | Rendered as |
|--------|----------------------|-------------|
| `node` | The built-in RAG graph — one start/end per node (`guard`…`suggest`). The coarse `status.stage` is the summary; `node` beats are the fine-grained timeline. | Pipeline step (spinner → ✓/✗/degraded) |
| `subagent` | **Reserved** in Phase 1 (the built-in graph is linear, no fan-out). A hosted/durable agent that spawns workers streams a `subagent` beat wrapping that worker's own nested `tool_use`/`node` children. | Nested, collapsible activity group |
| `skill` | **Reserved** in Phase 1 (the skill/memory *review* pass is explicitly post-Phase-1, [agent-graph.md](./agent-graph.md) Self-improvement). When present, a `skill` beat marks a procedural-memory/skill activation. | Labeled badge in the activity trail |
| `planner` | **Reserved** — a plan/decompose step for a multi-step agent. | Plan node |

**Boundary rules (these are load-bearing, not cosmetic).**
- `agent_step.detail` and `tool_use.input`/`tool_result.output` are **display hints only** — never an access decision and never authoritative. The authoritative result, spend, and audit live in Postgres ([data-model.md](../data-model.md)); a dropped or truncated beat is cosmetic (same guarantee as a dropped `token`).
- `tool_use.input` is **redacted server-side before emission** — no secrets, PATs, or PII cross the wire (OWASP A09/L2; the MCP tool boundary owns enforcement, [mcp-tools.md](./mcp-tools.md)).
- A tool the agent is **not** authorized to call never appears as a `tool_use` — authorization is decided at the tool boundary before any emission, so the stream can't advertise a capability the caller can't use (SC-001).
- Sub-agent/skill activity is **observation of the run**, not a control channel: the browser cannot start/stop a sub-agent via this stream. The only member→run control path is the HITL `approval_request` → `POST /approvals/{id}/resolve` loop (FR-040).

## Streams

### Query stream — `GET /query/{streamId}` (US2)
- Ordered emission: `status` (stages: `moderating`, `rewriting`, `retrieving`, `reranking`, `generating`) → interleaved agentic activity (`thinking` / `agent_step` node beats / correlated `tool_use`+`tool_result` pairs) → `token` deltas → `done` → `suggestions` (when applicable, FR-031). Ordering is guaranteed only *across* stages and per-`id` (a `tool_use`/`agent_step:start` precedes its matching `tool_result`/`agent_step:end`); concurrent tool calls may interleave and are re-associated client-side by `id`/`parent_id` (see Agentic activity).
- A `ping` keepalive may be emitted at any time on an idle long-lived stream to keep the connection open through proxies; it carries no run meaning and the client MUST ignore it (never counts toward tokens, ordering, or spend).
- `suggestions` is emitted after `done` only when `source_count > 0` and the answer was not refused; contains 2–3 clearance-scoped follow-up question strings. Omitted entirely on moderation block or zero-source answer.
- **`clarification` replaces the answer, it does not interrupt one** (FR-045). When the `route` node judges the question materially ambiguous, the stream emits `clarification` **instead of** `token` deltas, then `done` — no `suggestions`, no partial answer, and **no `status.stage='paused'`**. The member's selection arrives as an ordinary `POST /query` carrying `clarifies: { id, option_id? }`, which is a **new run** with its own `stream_id`. Nothing is held open: this is deliberately *not* the `approval_request` mechanism, which pauses a durable run and holds spend — a clarification pauses nothing, so it works in the interactive form where `approval_request` cannot. The turn is metered as a normal (cheap, `fast`-alias) generation; it is real inference and must not become an unbilled path.
- On moderation block: a single `error` with code `injection_blocked` or `disallowed`, no `token`/`done`/`suggestions`, no credit spend (FR-010, SC-007).
- `done.credits_deducted` reflects the exact charge (must reconcile to the ledger, SC-006).
- **Durable (`long_horizon`) runs only** may additionally emit an `approval_request` event when the graph pauses at the `human_gate` node (FR-040): a `status.stage='paused'` precedes it, no further `token`/spend follows until the member resolves it (`POST /approvals/{id}/resolve`), and a `status.stage='resumed'` marks the run continuing past the gate. Interactive queries never pause, so they never emit `approval_request` ([agent-graph.md](./agent-graph.md) Human-in-the-loop).

### Ingestion stream — `GET /ingest/{jobId}/status` (US1)
- `status.stage` progression: `received` → `converting` → `extracting_metadata` → `chunking` → `embedding` → `indexed`.
- Terminal error stages via `error.code`: `unsupported_type` (video/audio stub), `oversize`, `dlq_parked`, `failed` — never a silent stall (FR-003).

### Note-enrich stream — `GET /notes/{id}/enrich/{streamId}` (US1, FR-001)
- Interactive generation (member waits for a draft), so it mirrors the query-stream shape and reuses the same event taxonomy — no new event *types*.
- `status.stage` progression: `fetching` → `distilling` → `drafting` → `token` deltas → `done`.
- A link that fails the SSRF guard or fetch is surfaced via a `status` stage (skipped link) — one bad URL never fails the whole draft.
- The draft is **not persisted**; it lives client-side until the member accepts (`POST /notes/{id}`), which then enters the normal ingestion stream above.
- `done.credits_deducted` reflects the exact charge (`operation_type='enrich'`), reconciling to the ledger like any generation (SC-006).

### Notification stream — `GET /notifications/stream` (US8)
- Long-lived per-user stream relaying the recipient's notifications from Redis pub/sub (`notify:user:<user_id>`) as SSE.
- On connect: emits an initial `unread_count`. Thereafter, each new notification emits a `notification` event followed by an updated `unread_count`.
- De-duplication happens server-side via the notification's `idem_key` before persistence/push (FR-032, SC-013), so a redelivered upstream event never produces a duplicate `notification` event on the wire; `idem_key` itself is internal and not serialized to the client.
- Only the authenticated caller's own notifications are emitted; cross-member/cross-workspace delivery is impossible by construction (FR-036, SC-012).
- Being long-lived and mostly idle, this stream emits periodic `ping` keepalives; the client ignores them and treats a missed heartbeat window as a reconnect signal.

## Debug trace (companion to the query stream)

Fetched via `GET /query/{streamId}/debug` for the debug panel (FR-021). The response is a **section envelope**, not a fixed struct — the run-detail equivalent of the additive-`kind` rule that governs `agent_step` above. The renderer contract and its conformance gate live in [stream-ui-ports.md](./stream-ui-ports.md).

```typescript
interface DebugResponse {
  sections: TraceSection[];   // Phase 1 emits exactly one: kind="rag_retrieval"
  summary: RunSummary;        // { usage?, traceUrl?, extra? }
}

interface TraceSection {
  kind: string;        // "rag_retrieval" | "planner" | "eval" | host-defined
  label: string;       // human-readable section header
  payload: unknown;    // OPAQUE to the panel kernel — shape owned by the registered renderer
  order?: number;      // optional display rank; stable sort, ties by arrival
}
```

**Why an envelope rather than a struct.** A fixed `DebugTrace` asserts on the *wire* that every run is a RAG run: a host with a different pipeline must fork the shape to say anything, and a host with *several* detail views (retrieval **and** a planner trace **and** an eval breakdown) cannot express that without widening the struct for everyone. The envelope makes run-detail additive by `kind` — exactly as `agent_step` made activity additive by `kind` — so a new inspector is a registered renderer, never a schema change (coupling #1, [stream-ui-ports.md](./stream-ui-ports.md)).

The Phase 1 `rag_retrieval` payload is the retrieval trace **unchanged**, moved one level down:

```typescript
// The unit every retrieval stage reports. Deliberately NOT {id, score}: an opaque hash list is a
// readout, not a diagnostic. `title` + `preview` make a row legible, and `access_level`/`scope` make
// the clearance story checkable at a glance (SC-005).
interface ScoredChunk {
  chunk_id: string;
  document_id: string;
  title: string;                  // human-readable doc title — never a bare hash
  preview: string;                // short snippet, server-side redacted + truncated
  score: number;                  // this stage's score (scale differs per stage; compare within a stage only)
  rank: number;                   // 1-based rank within this stage
  access_level: number;           // the chunk's own level — ALWAYS ≤ the requester's clearance (see below)
  scope: "personal" | "workspace";
}

// One stage of the retrieval funnel. `in`/`out` + `cutoff` are what turn five parallel score arrays
// into an answerable question: not "what were the scores" but "what got dropped, where, and why".
interface FunnelStage {
  stage: "bm25" | "vector" | "rrf" | "clearance_filter" | "rerank" | "expand";
  in: number;                     // candidates entering
  out: number;                    // candidates leaving
  cutoff: number | null;          // the score line drawn at this stage — null when the stage doesn't score
  duration_ms: number;            // per-stage latency (finding: the panel had NO timing at all)
  chunks: ScoredChunk[];          // top-N at this stage, INCLUDING entries below `cutoff` so the near-misses are visible
  note?: string;                  // e.g. "reranker unavailable — RRF order retained (degraded)"
}

interface UsedChunk extends ScoredChunk {
  cited: boolean;                 // did the ANSWER actually cite it? retrieved ≠ used, and conflating
                                  // them is why "is this grounded?" was previously unanswerable
  citation_markers: number[];     // the [1] [2] markers in the answer that point here
}

interface AccessFilter {          // structured — the old free-text string could not be asserted on
  requester_clearance: number;
  removed_by_clearance: number;   // COUNT ONLY, never identities (see the privacy note below)
  removed_by_group: number;       // Phase 2
  pre_filter: true;               // always a pre-filter on the store, never a post-filter on ANN results
}

interface MemoryTrace {           // was a single opaque string — in the one place opacity is dangerous
  injected: { id: string; text: string; access_level: number }[];
  elided_low_salience: number;    // dropped deterministically for budget, never at random
  elided_above_clearance: number; // stamped above the requester's CURRENT clearance (e.g. post-demotion)
}

interface RagRetrievalPayload {   // = TraceSection.payload where kind === "rag_retrieval"
  intent: "semantic" | "structured" | "long_horizon";
  tool_called: string;
  index_tier: "HOT" | "COLD";
  chunk_type: string;             // "child → parent expanded"
  funnel: FunnelStage[];          // ordered; replaces bm25/vector/rrf/reranker_before/reranker_after
  used: UsedChunk[];              // what actually reached the model, with citation mapping
  access_filter: AccessFilter;
  memory: MemoryTrace;
  model_used: string;
  langfuse_trace_url: string;     // also surfaced as DebugResponse.summary.traceUrl
}
```

**Why a funnel instead of five score arrays.** The previous shape (`bm25_scores`, `vector_scores`, `rrf_merged`, `reranker_before`, `reranker_after`) reported *data* and left the reader to join five parallel lists by eye. It could not answer the question the panel exists for — **"why isn't my document here?"** The funnel answers it directly: each stage states what entered, what left, and where the line was drawn.

**How the funnel distinguishes the two reasons a document is missing — without leaking anything.** A document vanishes for one of two very different reasons, and conflating them was the panel's most useful missing distinction:

- **It scored too low.** The chunk is readable by the requester, so it appears in the `bm25`/`vector` stage `chunks` **below that stage's `cutoff`** — visibly a near-miss, with its real score.
- **It was filtered by clearance.** It is by definition *not* readable by the requester, so it appears **only** in `access_filter.removed_by_clearance` as a count, never as a row.

That split is not a compromise, it is exactly right: a chunk you may read can be shown with its score; a chunk you may not read must not be nameable, or the panel becomes an existence oracle for above-clearance documents (SC-001). So `ScoredChunk.access_level` is always ≤ the requester's clearance by construction — a row above it appearing anywhere in the funnel is a security defect, not a display bug.

`token_cost` and `credits_deducted` move to the `cost` section below, where they can be broken down per call rather than collapsed into one unattributable number.

### Section `grounding` — is this answer actually supported?

The single most valuable question a debug panel answers, and the one the original shape could not: it showed what was *retrieved*, the thread showed citations, and nothing joined them.

```typescript
interface GroundingPayload {      // TraceSection.payload where kind === "grounding"
  claims: Claim[];
  unused_chunks: { chunk_id: string; title: string; rank: number }[];  // retrieved, reached the model, never cited
  unsupported_claim_count: number;   // claims with zero supporting chunk — the hallucination signal
}

interface Claim {
  text: string;                   // one assertion from the answer
  supported_by: string[];         // chunk_ids backing it; EMPTY = unsupported, and rendered as a warning
  citation_markers: number[];     // the [n] markers shown inline for this claim
}
```

**`supported_by: []` is the finding, not an error.** An unsupported claim is not necessarily wrong — it may be a connective sentence or a legitimate synthesis — but it is the one thing a reviewer must be able to see. Rendering it as a distinct, amber state (never hidden, never silently equivalent to a cited claim) is what makes the panel a grounding check rather than a readout. `unused_chunks` is the mirror image and is just as diagnostic: content that survived the whole funnel, entered the context, and contributed nothing usually means the retrieval was right and the *prompt* was wrong.

### Section `cost` — where the credits actually went

```typescript
interface CostPayload {           // TraceSection.payload where kind === "cost"
  calls: CostCall[];
  total_credits: number;          // MUST equal done.credits_deducted and reconcile to the ledger (SC-006)
}

interface CostCall {
  stage: string;                  // "rewrite" | "rerank" | "generate" | "vision" | "caption" | …
  alias: string;                  // "fast" | "smart" | "rerank" | "vision"
  input_tokens: number;
  output_tokens: number;
  image_tokens?: number;          // vision only — priced by tile/resolution, so it varies by an order of magnitude
  credits: number;
  duration_ms: number;
  fallback_hops: 0 | 1;           // a one-hop provider fallback changes both cost and latency
}
```

One number could not answer *"why did this cost 42 credits?"*, and adding query-time vision (FR-044) made that materially worse — image tokens vary by an order of magnitude with resolution, so a single total hides the one input most likely to explain a surprising bill.

### Live sections — the panel fills as the run happens

```typescript
| { event: "trace_section"; data: TraceSection }   // a section, emitted the moment its stage completes
```

Previously the panel was populated only by `GET /query/{streamId}/debug` **after** the run, while the activity trail streamed live — so during the moments a developer most wants to watch, the drawer was empty and the richer view arrived once it was no longer urgent.

Sections now stream: `retrieve` completing emits `rag_retrieval`, `generate` completing emits `grounding` and `cost`. The `GET` endpoint remains authoritative and unchanged — it is what a page reload or a later visit fetches, and it returns the same sections. A client that receives a section twice (streamed, then re-fetched) keeps the fetched copy; sections are **idempotent by `kind`**, not appended.

**Ordering.** A `trace_section` may arrive at any point before `done`; it never interleaves *within* a token and carries no run meaning for ordering purposes. A client that ignores `trace_section` entirely still renders a correct run and gets the full set from the `GET` — so the event is additive, not required.

## Contract test obligations

- Every completed query produces a `DebugResponse` carrying a `rag_retrieval`, a `grounding`, and a `cost` section, each fully populated (FR-021, SC-005).
- **Funnel integrity:** the stages are ordered and **conserve candidates** — each stage's `in` equals the previous stage's `out`, and `clearance_filter.out == in - removed_by_clearance - removed_by_group`, so a silently dropped chunk is a test failure rather than an invisible one. Every stage reports a `duration_ms`, and every scoring stage reports a `cutoff`.
- **Near-miss visibility:** a chunk the requester **can** read that scored below a stage's `cutoff` **appears** in that stage's `chunks` with its real score (so "why isn't my document here?" is answerable), while a chunk removed by clearance appears **only** in `access_filter.removed_by_clearance` as a count.
- **No above-clearance row anywhere (SC-001, release blocker):** across every `funnel[].chunks`, `used[]`, and `grounding.unused_chunks`, no entry has `access_level >` the requester's clearance and none belongs to another member's personal scope or another workspace. The panel must never become an existence oracle for content the member cannot read — asserted adversarially alongside T144/T145.
- **Grounding:** every `[n]` citation marker in the answer resolves to a `used[]` chunk with `cited: true`; a chunk that reached the model but was never cited appears in `unused_chunks`; and a claim with no supporting chunk is reported with `supported_by: []` and counted in `unsupported_claim_count` rather than being rendered as though it were cited.
- **Cost reconciliation:** `cost.total_credits` equals `done.credits_deducted` and the sum of `calls[].credits`, and reconciles to the ledger (SC-006). A `vision` call reports `image_tokens`; a one-hop provider fallback is reflected in `fallback_hops`.
- **Memory trace:** `memory.injected[]` lists each injected memory with its stamped `access_level`, all ≤ the requester's **current** clearance; budget-driven drops are counted in `elided_low_salience` and clearance-driven ones in `elided_above_clearance` — never silently omitted (SC-005, and the demotion case in research §13).
- **Live sections:** `rag_retrieval` arrives on a `trace_section` event before `done` (not only from the `GET`), the `GET` returns the same sections after completion, a section re-delivered by both paths is **replaced by `kind`, never duplicated**, and a client that ignores `trace_section` entirely still renders a correct run.
- **Section forward-compat:** a `DebugResponse` containing an **unrecognized** `section.kind` is accepted by the typed client and rendered through the generic fallback — never dropped and never an error — the run-detail analogue of the additive-`kind` guarantee for `agent_step` ([stream-ui-ports.md](./stream-ui-ports.md)).
- A moderation-blocked query emits exactly one `error` event and no `done`/`token` events and zero credit spend (SC-007).
- **Clarification (FR-045):** a materially-ambiguous query emits exactly one `clarification` (2–4 options, `allow_custom: true`) followed by `done`, and emits **no** `token`, **no** `suggestions`, and **no** `status.stage='paused'` — asserting it is a terminal response rather than an interrupt. The follow-up `POST /query` carrying `clarifies.id` opens a **new** `stream_id` and answers normally. The clarification turn produces a real (small) `done.credits_deducted` that reconciles to the ledger like any generation — it is never a free path (SC-006).
- A `long_horizon` run that pauses at the human-gate emits exactly one `approval_request` event (after `status.stage='paused'`) and no further `token`/`done`/spend until resolved; on approve it emits `status.stage='resumed'` and continues, on reject it ends without indexing (FR-040, SC-014).
- An oversize/unsupported ingestion emits a terminal `error` stage, not an indefinite `status` (FR-003, SC-010).
- The notification stream emits an initial `unread_count` on connect and a `notification` + `unread_count` pair per new event, and never emits another member's or another workspace's notification (FR-034, SC-012).
- **Heartbeat:** a long-lived idle stream (query awaiting a durable resume, or the notification stream) emits at least one `ping` within the keepalive window, and the typed client ignores `ping` entirely — it never appears in rendered tokens, never advances ordering, and never affects `done.usage`/spend.
- **Tool correlation:** every `tool_use` on a stream is matched by exactly one `tool_result` sharing the same `id`; a failed call surfaces `tool_result.status='error'` (never inferred from `output` text), and concurrent `tool_use` events with distinct `id`s pair to their own results regardless of interleaving.
- **Agent-step lifecycle:** every `agent_step` with `phase:'start'` is closed by a matching `phase:'end'` under the same `id` carrying a terminal `status`; children reference an existing parent via `parent_id` (no orphan beat), and an unknown `kind` is accepted by the client and rendered as a generic row rather than dropped or erroring (forward-compat, additive-`kind` guarantee).
- **No secret leakage:** `tool_use.input` and `tool_result.output` emitted on the wire contain no secrets/PATs/PII (server-side redaction), and a tool the caller is not authorized to invoke never appears as a `tool_use` (OWASP A09/L2, SC-001).
