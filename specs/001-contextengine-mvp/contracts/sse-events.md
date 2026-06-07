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
```

## Streams

### Query stream — `GET /query/{streamId}` (US2)
- Ordered emission: `status` (stages: `moderating`, `rewriting`, `retrieving`, `reranking`, `generating`) → interleaved `thinking` / `tool_use` / `tool_result` → `token` deltas → `done`.
- On moderation block: a single `error` with code `injection_blocked` or `disallowed`, no `token`/`done`, no credit spend (FR-010, SC-007).
- `done.credits_deducted` reflects the exact charge (must reconcile to the ledger, SC-006).

### Ingestion stream — `GET /ingest/{jobId}/status` (US1)
- `status.stage` progression: `received` → `converting` → `extracting_metadata` → `chunking` → `embedding` → `indexed`.
- Terminal error stages via `error.code`: `unsupported_type` (video/audio stub), `oversize`, `dlq_parked`, `failed` — never a silent stall (FR-003).

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
