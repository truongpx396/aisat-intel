# Contract: SSE Event Taxonomy

**Plan**: [../plan.md](../plan.md) | The streaming contract between the Go BFF and the React SPA (`frontend/src/lib/sse.ts`). The BFF relays Python worker output (via Redis pub/sub keyed by `stream_id`) as Server-Sent Events.

> **Relay is a separable tier (locked in Phase 1, research §14).** The SSE relay subscribes to Redis pub/sub by `stream_id` and forwards only — it holds no request-handling logic. Phase 1 MAY co-deploy it with the request-handling BFF, but the clean boundary lets Phase 4 split it into an independently connection-scaled tier without touching handlers.

> **Why Redis pub/sub, not JetStream, for the streaming hop.** Work dispatch (BFF→worker) uses JetStream because a job must be durable, redeliverable, and lag-measurable. The live-token hop (worker→relay→browser) is ephemeral fan-out to an already-connected client, so it uses Redis pub/sub keyed by `stream_id`: lowest latency, trivial per-stream fan-out, fire-and-forget. A dropped token is cosmetic — credits, audit, and the final answer/citations are authoritative in Postgres, not the stream. JetStream here would add per-token persistence and per-query consumer churn for no benefit. Replay-on-reconnect (not a Phase 1 requirement) would be a **Redis Stream** (`XADD`/`XREAD`), still not JetStream.
>
> **Scaling caveat (Phase 4, do not defer the decision).** Classic Redis `PUBLISH`/`SUBSCRIBE` is **broadcast across the entire cluster bus** under Redis Cluster — every node receives every message regardless of which relay replica needs it. So the moment Redis moves to Cluster for HA, the streaming hop MUST switch to **sharded pub/sub** (`SPUBLISH`/`SSUBSCRIBE`, Redis 7+) keyed by a **slot-hash-tagged `stream_id`** (`{stream}:<id>`), so a token reaches only the relay replicas on that stream's shard. This makes the separable-relay decision (above) and the Redis-Cluster move a **single coupled workstream, not two independent phases** — tracked jointly in [research §10](../research.md) and [draft-plan Phase 4 items 2 + 6](../../draft-plan.md#6-redis-high-availability). It is a config/keying change (no event-taxonomy change), because any relay replica already serves any `stream_id` with no sticky sessions.

## Event types

```typescript
type SSEEventType =
  | { event: "token";       data: { content: string } }
  | { event: "thinking";    data: { content: string } }
  | { event: "tool_use";    data: { name: string; input: unknown } }
  | { event: "tool_result"; data: { name: string; output: string } }
  | { event: "status";      data: { stage: string } }
  | { event: "error";       data: { code: string; message: string } }
  | { event: "done";        data: { usage: { input: number; output: number }; credits_deducted: number } }
  | { event: "suggestions"; data: { questions: string[] } }  // FR-031: 2–3 follow-up chips, only when source_count > 0 and answer was not refused
  | { event: "approval_request"; data: ApprovalRequest }      // FR-040: a durable run paused for a human decision (HITL)
  | { event: "notification";  data: Notification }            // FR-034: a new notification for the connected recipient
  | { event: "unread_count";  data: { unread: number } }      // FR-034: updated bell badge count
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

interface ApprovalRequest {           // FR-040 — a human-in-the-loop gate awaiting the connected member
  id: string;
  kind: "enrich_accept" | "long_horizon_action" | "sensitivity_confirm" | "web_search" | "note_edit";  // FR-040/FR-041
  subject_ref: Record<string, unknown>;  // what is gated: { note_id } | { run_id, step } | { doc_id }
  prompt: string;                     // human-readable "what am I approving?"
  payload: Record<string, unknown>;   // detail for the UI: { suggested_level } | draft ref | step description
  expires_at: string | null;          // fail-closed deadline; null = no expiry
}

## Streams

### Query stream — `GET /query/{streamId}` (US2)
- Ordered emission: `status` (stages: `moderating`, `rewriting`, `retrieving`, `reranking`, `generating`) → interleaved `thinking` / `tool_use` / `tool_result` → `token` deltas → `done` → `suggestions` (when applicable, FR-031).
- `suggestions` is emitted after `done` only when `source_count > 0` and the answer was not refused; contains 2–3 clearance-scoped follow-up question strings. Omitted entirely on moderation block or zero-source answer.
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

## Debug trace (companion to the query stream)

Fetched via `GET /query/{streamId}/debug` for the debug panel (FR-021); shape:
```typescript
interface DebugTrace {
  intent: "semantic" | "structured" | "long_horizon";
  tool_called: string;
  index_tier: "HOT" | "COLD";
  access_filter: string;          // e.g. "level <= 2, filtered 3 docs"
  bm25_scores: ScoredChunk[];
  vector_scores: ScoredChunk[];
  rrf_merged: ScoredChunk[];
  reranker_before: ScoredChunk[];
  reranker_after: ScoredChunk[];
  chunk_type: string;             // "child → parent expanded"
  mem0_injected: string;
  model_used: string;
  token_cost: number;
  credits_deducted: number;
  langfuse_trace_url: string;
}
```

## Contract test obligations

- Every completed query produces a `DebugTrace` with all fields populated, including `access_filter` (count of docs filtered by clearance) and `credits_deducted` (FR-021, SC-005).
- A moderation-blocked query emits exactly one `error` event and no `done`/`token` events and zero credit spend (SC-007).
- A `long_horizon` run that pauses at the human-gate emits exactly one `approval_request` event (after `status.stage='paused'`) and no further `token`/`done`/spend until resolved; on approve it emits `status.stage='resumed'` and continues, on reject it ends without indexing (FR-040, SC-014).
- An oversize/unsupported ingestion emits a terminal `error` stage, not an indefinite `status` (FR-003, SC-010).
- The notification stream emits an initial `unread_count` on connect and a `notification` + `unread_count` pair per new event, and never emits another member's or another workspace's notification (FR-034, SC-012).
