# Contract: SSE Event Taxonomy

**Plan**: [../plan.md](../plan.md) | The streaming contract between the Go BFF and the React SPA (`frontend/src/lib/sse.ts`). The BFF relays Python worker output (via Redis pub/sub keyed by `stream_id`) as Server-Sent Events.

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
  | { event: "notification";  data: Notification }            // FR-034: a new notification for the connected recipient
  | { event: "unread_count";  data: { unread: number } }      // FR-034: updated bell badge count
```

```typescript
interface Notification {
  id: string;
  category:
    | "ingestion_complete" | "ingestion_failed"
    | "invite_received" | "invite_accepted" | "invite_revoked"
    | "credit_warning" | "credit_exhausted" | "task_halted"
    | "doc_shared" | "clearance_changed" | "member_joined" | "admin_broadcast";
  priority: "info" | "warning" | "critical";
  title: string;
  body: string;
  payload: Record<string, unknown>;  // deep-link refs, e.g. { doc_id }, { invite_id }, { run_id }
  read_at: string | null;
  created_at: string;
}

## Streams

### Query stream — `GET /query/{streamId}` (US2)
- Ordered emission: `status` (stages: `moderating`, `rewriting`, `retrieving`, `reranking`, `generating`) → interleaved `thinking` / `tool_use` / `tool_result` → `token` deltas → `done` → `suggestions` (when applicable, FR-031).
- `suggestions` is emitted after `done` only when `source_count > 0` and the answer was not refused; contains 2–3 clearance-scoped follow-up question strings. Omitted entirely on moderation block or zero-source answer.
- On moderation block: a single `error` with code `injection_blocked` or `disallowed`, no `token`/`done`/`suggestions`, no credit spend (FR-010, SC-007).
- `done.credits_deducted` reflects the exact charge (must reconcile to the ledger, SC-006).

### Ingestion stream — `GET /ingest/{jobId}/status` (US1)
- `status.stage` progression: `received` → `converting` → `extracting_metadata` → `chunking` → `embedding` → `indexed`.
- Terminal error stages via `error.code`: `unsupported_type` (video/audio stub), `oversize`, `dlq_parked`, `failed` — never a silent stall (FR-003).

### Notification stream — `GET /notifications/stream` (US8)
- Long-lived per-user stream relaying the recipient's notifications from Redis pub/sub (`notify:user:<user_id>`) as SSE.
- On connect: emits an initial `unread_count`. Thereafter, each new notification emits a `notification` event followed by an updated `unread_count`.
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
- An oversize/unsupported ingestion emits a terminal `error` stage, not an indefinite `status` (FR-003, SC-010).
- The notification stream emits an initial `unread_count` on connect and a `notification` + `unread_count` pair per new event, and never emits another member's or another workspace's notification (FR-034, SC-012).
