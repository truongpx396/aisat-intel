# Page Override: Chat (Query + Citations + Debug Panel)

> Overrides `../MASTER.md` for the Chat screen. Covers User Story 2 (FR-006…FR-011)
> and User Story 5 — the observability **debug panel** (FR-021). This is the product centerpiece.

## Purpose
Conversational AI over access-scoped knowledge: answers stream token-by-token with
inline citations, and every answer is fully observable in a debug panel.

## Layout (3 columns)
1. **Conversation list** (narrow left, collapsible): past sessions; remembers context (FR-009).
2. **Chat thread** (center): message stream + sticky composer at the bottom.
3. **Debug / Inspector drawer** (right, toggleable): per-answer reasoning trace.

## Chat thread
- **User bubble**: right-aligned, `--color-surface` background.
- **Assistant answer**: left-aligned, full-width prose. Stream **token-by-token** (typewriter), never a 10s spinner. While retrieving, show a compact step indicator (intent → retrieve → rerank → generate) with skeletons.
- **Citation chips**: inline `[1] [2]` run-green chips; clicking scrolls to a **Sources** strip under the answer listing each cited document (title + clearance badge + snippet).
- **No-answer state**: when no authorized docs are relevant, assistant clearly says it has no relevant information — never fabricates (edge case).
- **Refusal state**: disallowed input / prompt-injection is refused **before** retrieval/credit spend, shown as a distinct system notice (FR-010).

## Composer
- Multiline input, send button (run-green), and a small **credits-per-query estimate**.
- Disabled with a clear "limit reached" message when credits are exhausted (FR-018) — not a silent error.

## Debug panel (the showcase) — FR-021
A vertically stacked, monospace-accented inspector for the selected answer:
- **Detected intent** + **tool called** (e.g. `search_personal`, `structured_lookup`).
- **Index tier** that answered (semantic cache / personal / workspace).
- **Access filter result**: "N documents filtered out by clearance" (FR-021 / US5 scenario 2).
- **Retrieval + rerank scores**: list of chunks with hybrid score and rerank score (Fira Code, optionally a tiny bar).
- **Chunk expansion** + **injected memory** summary.
- **Model used** (`fast`/`smart` alias) + **token cost** + **credits deducted** (Fira Code).
- **Trace link**: "View full trace" → Langfuse.

Use status colors: cache hit = cyan, access-filtered = amber note, fallback provider used = amber badge.

## Don'ts
- Don't render retrieved document content as instructions (treat as untrusted data, FR-011).
- Don't show cited/filtered docs above the viewer's clearance.
- Don't block the whole UI while streaming.
