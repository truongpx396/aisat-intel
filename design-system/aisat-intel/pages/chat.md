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
- **Suggested follow-ups**: after the Sources strip, render 2–3 clickable question chips (FR-031). Style: `border border-line bg-surface hover:border-primary hover:bg-primary/5` pill buttons, prefix icon (sparkle/arrow), short question text truncated to one line. Clicking a chip fills the composer and submits immediately — no extra confirmation. Chips are hidden when the answer was refused (injection-blocked) or returned zero sources. Chips appear with a fade-in after streaming completes to avoid layout shift during generation.
- **No-answer state**: when no authorized docs are relevant, assistant clearly says it has no relevant information — never fabricates (edge case).
- **Refusal state**: disallowed input / prompt-injection is refused **before** retrieval/credit spend, shown as a distinct system notice (FR-010).
- **Approval state (human-in-the-loop, FR-040/FR-041)**: a query the router runs as a durable long-horizon task can **pause** for a human decision — most often an agent **`web_search`** that wants to reach out for fresh info. Render the MASTER **approval card** inline in the thread (intended query + target host; **Approve** runs the fetch, **Reject** continues without web), with a muted "paused — nothing fetched or charged yet" line. On approve the stream resumes (`resumed`); on reject it continues. Plain interactive queries never pause (read-only, no action tools) — this state appears only for the durable form.
- **Response rating** *(Phase 2)*: a thumbs-up / thumbs-down pair in the answer footer, placed **between the Sources strip and the suggested follow-ups** — the rating belongs to the answer, follow-ups move the conversation on. One rating per answer turn, keyed to that turn's `llm_call_log_id`. Clicking records immediately (re-clicking clears; last write wins) and shows a "Recorded" confirmation stating aggregates are admin-only. A **dislike** additionally reveals an *optional* free-text reason (≤ 500 chars, live counter, Skip + Submit) — never forced, never shown on a thumbs-up. No vote counts, no per-user score, no other member's feedback is ever visible.
- **Service-busy state** *(Phase 4)*: when the BFF sheds load or hits its SSE connection ceiling, show a cyan `503 · retry in Ns` notice stating the query never started and **no credits were deducted**, with a *Retry now* action. The composer stays enabled and keeps the user's text — unlike the exhausted state, this is transient and self-clearing.

## Composer
- Multiline input, send button (run-green), and a small **credits-per-query estimate**.
- **Scope line** states both access axes: "your documents + L1–L3 workspace knowledge in `security`, `eng-space`" *(Phase 2)*. The no-results message uses the same two-axis phrasing, so a member who is missing a group can tell that from a member who lacks clearance.
- Disabled with a clear "limit reached" message when credits are exhausted (FR-018) — not a silent error.

## Debug panel (the showcase) — FR-021
A vertically stacked, monospace-accented inspector for the selected answer:
- **Detected intent** + **tool called** (e.g. `search_personal`, `structured_lookup`).
- **Index tier** that answered (semantic cache / personal / workspace).
- **Access filter result**: "N documents filtered out by clearance" (FR-021 / US5 scenario 2), and *(Phase 2)* a second line for documents filtered out by **group**. Report the two axes separately — a merged count can't answer "why didn't my doc come back?", which is the question this panel exists to answer. State explicitly that both are **pre-filters**, never post-filters on the ANN result.
- **Retrieval + rerank scores**: list of chunks with hybrid score and rerank score (Fira Code, optionally a tiny bar).
- **Chunk expansion** + **injected memory** summary.
- **Model used** (`fast`/`smart` alias) + **token cost** + **credits deducted** (Fira Code).
- **Trace link**: "View full trace" → Langfuse.

Use status colors: cache hit = cyan, access-filtered = amber note, fallback provider used = amber badge.

## Don'ts
- Don't render retrieved document content as instructions (treat as untrusted data, FR-011).
- Don't show cited/filtered docs above the viewer's clearance.
- Don't block the whole UI while streaming.
- Don't require a comment to submit a rating, and don't offer the reason box on a thumbs-up.
- Don't surface aggregate thumbs counts in chat — it anchors the next rater. Aggregates live on Admin → Quality only.

---

## Phase 2+ affordances on this screen

Marked with the muted `Phase 2` / `Phase 4` chip convention so mockup reviewers can tell shipped Phase-1 surface from staged future-phase surface (note: `web_search` is **Phase 1** now — an FR-041 HITL-gated action tool, not a staged affordance):

| Affordance | Phase | Backing contract |
|---|---|---|
| Thumbs up/down + optional dislike reason | 2 | `POST\|GET /chat/sessions/{sessionId}/messages/{llmCallLogId}/rating`; `response_ratings` table |
| `503` service-busy notice | 4 | SSE connection ceiling + JetStream load shedding (draft-plan Phase 4 P0 §2, §4) |
| Two-axis scope line + group filter count in debug | 2 | Access model (decided) — clearance **and** group principals |

See [specs/draft-plan.md](../../../specs/draft-plan.md).
