# Page Override: Chat (Query + Citations + Debug Panel)

> Overrides `../MASTER.md` for the Chat screen. Covers User Story 2 (FR-006…FR-011)
> and User Story 5 — the observability **debug panel** (FR-021). This is the product centerpiece.

## Purpose
Conversational AI over access-scoped knowledge: answers stream token-by-token with
inline citations, and every answer is fully observable in a debug panel.

## Layout (3 columns)
1. **Conversation list** (narrow left, collapsible): past sessions; remembers context (FR-009). See [Conversation list](#conversation-list--fr-009) below.
2. **Chat thread** (center): message stream + sticky composer at the bottom.
3. **Debug / Inspector drawer** (right, toggleable): per-answer reasoning trace.

## Chat thread
- **User bubble**: right-aligned, `--color-surface` background.
- **Assistant answer**: left-aligned, full-width prose. Stream **token-by-token** (typewriter), never a 10s spinner.
- **Activity trail** (while the answer is being produced): a **nested, collapsible tree**, not a flat 4-step bar. It is driven by `agent_step` beats plus correlated `tool_use`/`tool_result` pairs ([sse-events.md](../../../specs/001-contextengine-mvp/contracts/sse-events.md)) and rendered by the generic `AgentTraceInspector` ([stream-ui-ports.md](../../../specs/001-contextengine-mvp/contracts/stream-ui-ports.md)):
  - **Nesting is by `parent_id`**, not by arrival order — a tool call renders *inside* the step that made it, and a sub-agent renders as a collapsible group wrapping its own children. Phase 1's built-in graph is linear, so the common case looks like today's `guard → route → rewrite → retrieve → rerank → assemble → memory → generate → suggest` list; the tree exists so a `subagent`/`skill`/`planner` run needs **no redesign**.
  - **Each row carries terminal status**: ✓ ok, ✗ error, and a distinct **degraded** treatment (amber) — a `rerank`→RRF fallback still *ended*, and must not read as a failure.
  - **Tool rows show the pair**: name/title while running, then `ok`/`error` + duration. A failed tool is styled from `tool_result.status`, **never** inferred from output text.
  - **Unknown `kind` renders as a generic collapsible row** — never dropped, never an error state. This is the additive-`kind` forward-compat guarantee made visible: a capability shipped after this mockup still renders.
  - **`thinking`** (model reasoning) is an **opt-in, collapsed-by-default** disclosure — never expanded automatically, never mistaken for the answer.
- **Citation chips**: inline `[1] [2]` run-green chips; clicking scrolls to a **Sources** strip under the answer listing each cited document (title + clearance badge + snippet).
- **Suggested follow-ups**: after the Sources strip, render 2–3 clickable question chips (FR-031). Style: `border border-line bg-surface hover:border-primary hover:bg-primary/5` pill buttons, prefix icon (sparkle/arrow), short question text truncated to one line. Clicking a chip fills the composer and submits immediately — no extra confirmation. Chips are hidden when the answer was refused (injection-blocked) or returned zero sources. Chips appear with a fade-in after streaming completes to avoid layout shift during generation.
- **Clarification state (FR-045)**: when a question is ambiguous in a way that would materially change the answer, the assistant's turn **is** the question. Render an inline card in the thread — never a modal, never an overlay — with a one-line question, 2–4 option chips (optional one-line detail each), and an always-present **"something else…"** free-text path. Selecting an option or typing a reply sends a **normal follow-up query**; nothing is paused, nothing is held, no run stays open. After resolution the card stays visible with the chosen option marked, so scroll-back reads coherently.
  - **Must not look like suggestion chips.** Suggestions (FR-031) are optional follow-ups *after* an answer; a clarification is a blocking question *before* one. Give the clarification card a container, a question line, and an affordance the suggestion chips don't have — if the two share a treatment, members will read a blocking question as an optional nicety and vice versa.
  - **Asking is the exception.** When the ambiguity is immaterial or one reading dominates, don't ask — answer and **state the assumption** ("assuming Q3 FY26 — ask again if you meant calendar Q3"). An assistant that interrogates on routine questions is worse than one that picks well and shows its work; SC-017 caps this at 10% of the eval set.
- **No-answer state**: when no authorized docs are relevant, assistant clearly says it has no relevant information — never fabricates (edge case).
- **Refusal state**: disallowed input / prompt-injection is refused **before** retrieval/credit spend, shown as a distinct system notice (FR-010).
- **Approval state (human-in-the-loop, FR-040/FR-041)**: a query the router runs as a durable long-horizon task can **pause** for a human decision — most often an agent **`web_search`** that wants to reach out for fresh info. Render the MASTER **approval card** inline in the thread (intended query + target host; **Approve** runs the fetch, **Reject** continues without web), with a muted "paused — nothing fetched or charged yet" line. On approve the stream resumes (`resumed`); on reject it continues. Plain interactive queries never pause (read-only, no action tools) — this state appears only for the durable form.
- **Response rating** *(Phase 2)*: a thumbs-up / thumbs-down pair in the answer footer, placed **between the Sources strip and the suggested follow-ups** — the rating belongs to the answer, follow-ups move the conversation on. One rating per answer turn, keyed to that turn's `llm_call_log_id`. Clicking records immediately (re-clicking clears; last write wins) and shows a "Recorded" confirmation stating aggregates are admin-only. A **dislike** additionally reveals an *optional* free-text reason (≤ 500 chars, live counter, Skip + Submit) — never forced, never shown on a thumbs-up. No vote counts, no per-user score, no other member's feedback is ever visible.
- **Service-busy state** *(Phase 4)*: when the BFF sheds load or hits its SSE connection ceiling, show a cyan `503 · retry in Ns` notice stating the query never started and **no credits were deducted**, with a *Retry now* action. The composer stays enabled and keeps the user's text — unlike the exhausted state, this is transient and self-clearing.

## Conversation list — FR-009

App chrome, **not** part of the reusable `stream-ui/` package — conversation history is a host persistence concern; the package renders *a* run, not the history of runs.

- **New chat** as a persistent action at the top of the column, never buried in an overflow menu.
- **Title**: derived once after the first turn from the `rewrite` node's normalized query (costs nothing — it is already computed), member-editable inline. A member-set title is never overwritten by the system. Truncate to one line with an ellipsis; the full title is the `title` attribute.
- **Grouping**: Today / Yesterday / Previous 7 days / Older, ordered by `last_message_at` — **not** `created_at`. A conversation replied to an hour ago belongs above one opened last week and abandoned; ordering by creation is the bug this rule exists to prevent.
- **Archive vs delete are different actions and must look different.** Archive hides the conversation and **keeps** its memory; delete destroys the conversation **and purges its Mem0 memories**. The delete confirmation states the memory purge in plain words — a member who reads "delete" as "remove from the list" has been misled about what the system still knows about them. Archive's confirmation says memory is retained.
- **Deleting state**: a row mid-purge shows an in-flight treatment and is not optimistically removed; if the purge fails it stays visible and retries rather than silently reappearing later.
- **Empty state**: first-time member sees a short prompt to start a conversation, not a bare "Recent" heading over nothing.
- **Overflow**: cursor-paginated "load more" — the list is not assumed to fit on screen.
- **Collapse**: the column collapses to an icon rail. If the control isn't built, don't describe the column as collapsible.
- **Scoping**: only the caller's own conversations, ever. A workspace peer at any clearance never sees another member's sessions, and a non-owner request reads as *not found* rather than *forbidden* (same existence-privacy rule as documents).

## Composer
- Multiline input, send button (run-green), and a small **credits-per-query estimate**.
- **Attachments (FR-043)**: attach button, drag-drop onto the composer, and paste-an-image. Each file gets a chip showing ingestion progress (`converting…` → `indexed`), with the library's own rejections surfaced inline — oversize (`413`) and unsupported video/audio (`501`). Nothing is accepted here that the library would refuse.
  - **Say that it is saved, before send.** An attachment is a real document in the member's **personal** library — private to them, browsable, deletable, and billed as an ingestion. The composer states this ("saved to your library · private to you") *before* the member sends. A member who believes an attached file is transient has been misled about what the system keeps.
  - Small files are answered **in the same turn** from converted text while indexing finishes in the background; large ones show progress and answer when indexed. Either way the chip ends at `indexed` and the document behaves like any other afterwards.
  - Deleting the **conversation** does not delete its attachments — they are the member's content. Deleting the **document** does. Don't conflate the two.
- **Scope chip (FR-042)**: when a question is scoped to specific documents, show a removable chip — "answering from: 2 documents" — with the unscoped query always one click away. An **"Ask about this"** action on library rows and citation chips opens chat pre-scoped. Scoping only ever *narrows*: it can never surface a document the member could not already read.
- **Images (FR-044)**: asking about an image runs a real multimodal call, not a lookup of the ingestion caption. When the vision call fails and the answer falls back to the caption, **say so** — "answered from the stored caption; the image itself wasn't examined." A caption-grounded answer presented as if the image had been read is the failure this rule exists to prevent.
- **Scope line** states both access axes: "your documents + L1–L3 workspace knowledge in `security`, `eng-space`" *(Phase 2)*. The no-results message uses the same two-axis phrasing, so a member who is missing a group can tell that from a member who lacks clearance.
- Disabled with a clear "limit reached" message when credits are exhausted (FR-018) — not a silent error.

## Debug panel (the showcase) — FR-021

The drawer is an **ordered list of labelled sections**, not one fixed form. AISAT's retrieval detail below is a single section (`kind: "rag_retrieval"`); a run that also produced a planner trace or an eval breakdown renders **additional** sections in the same drawer, and a section whose `kind` the client doesn't recognize renders as a **generic key-value table** rather than being dropped ([stream-ui-ports.md](../../../specs/001-contextengine-mvp/contracts/stream-ui-ports.md)). Give every section a header row with its `label` so the boundary is visible even when only one is present — that is what makes a second section look designed rather than bolted on.

**Sections fill as the run happens** — `rag_retrieval` appears when retrieval completes, `grounding` and `cost` when generation does. A drawer that stays empty until `done` is useless exactly when someone is watching.

### `rag_retrieval` — where did the context come from?

- **Detected intent** + **tool called** (e.g. `search_personal`, `structured_lookup`), and the **index tier** that answered.
- **The funnel, not five score lists.** Render retrieval as a narrowing: `9 candidates → 7 after clearance → 3 used`, each stage showing what entered, what left, its **duration**, and a **drawn cutoff line**. Five parallel score tables make the reader join them by eye; the funnel answers the actual question — *"where did my document fall out?"*
- **Near-misses must look like near-misses.** Show chunks that scored *below* the cutoff, greyed, beneath the line. A document that lost by 0.02 and one that was never retrieved are completely different problems, and an absence can't distinguish them.
- **Chunk rows are legible**: document title + a short preview + an `access_level` chip. Never a bare `chunk_id` — a wall of hashes is a readout, not a diagnostic.
- **Access filter**: requester clearance, plus **counts** removed by clearance and *(Phase 2)* by group, stated as **pre-filters**, never post-filters on the ANN result. Report the axes separately — a merged count can't answer "why didn't my doc come back?"
  - **Counts, never identities.** A clearance-removed document is one the member may not read, so naming it would turn the panel into an existence oracle (SC-001). This is the one deliberate blind spot, and it's the correct one: a chunk you *may* read is shown with its score, a chunk you may not is shown only as a number.
- **Injected memory** as a list — each memory with its stamped access level — plus counts of what was elided for budget vs. for clearance. A single "2 turns" string hides exactly the thing worth checking.
- **Chunk expansion**, **model used**, and the **Langfuse trace link** for anything deeper.

### `grounding` — is this answer actually supported?

The most valuable view in the panel, and the reason it's more than a readout.

- **Claim → sources.** Each assertion in the answer with the chunks backing it and its `[n]` markers.
- **An unsupported claim is a distinct amber state** — never hidden, never styled like a cited one. It isn't necessarily wrong (it may be connective prose), but it is the one thing a reviewer must be able to see at a glance.
- **Retrieved-but-uncited chunks** get their own list. Content that survived the whole funnel, entered the prompt, and contributed nothing usually means retrieval was right and the **prompt** was wrong — a different fix entirely.

### `cost` — where did the credits go?

Per call (`rewrite` / `rerank` / `generate` / `vision`): tokens, credits, duration, and fallback hops. Call out **`image_tokens`** separately — vision is priced by tile/resolution and varies by an order of magnitude, so it's the line most likely to explain a surprising bill. The total must match the answer's `credits_deducted`.

Use status colors: cache hit = cyan, access-filtered = amber note, fallback provider used = amber badge.

## Don'ts
- Don't render retrieved document content as instructions (treat as untrusted data, FR-011).
- Don't show cited/filtered docs above the viewer's clearance.
- Don't block the whole UI while streaming.
- Don't hide an activity row or a debug section just because its `kind` is unrecognized — degrade to a generic row/table. A blank panel is a worse failure than an ugly one.
- Don't style a `degraded` step as an error, and don't infer tool failure from output text — read `tool_result.status`.
- Don't auto-expand `thinking`, and never let it read as the answer.
- Don't render a chunk as a bare id — title + preview, or the panel is a wall of hashes.
- Don't show scores without the cutoff line; a score with no threshold explains nothing.
- Don't style an unsupported claim like a cited one, and never omit it — it is the hallucination signal.
- Don't name a clearance-filtered document, ever. Counts only (SC-001) — the panel must not become an existence oracle.
- Don't leave the drawer empty until `done`; sections arrive as their stage completes.
- Don't ask a clarifying question when one reading clearly dominates — answer and state the assumption instead.
- Don't render a clarification as a modal or an overlay; it is the assistant's turn and belongs in the thread.
- Don't offer a clarification without a free-text escape — a fixed menu that omits the member's actual meaning is worse than a guess.
- Don't imply an attachment is transient — it is a real personal-library document, billed and retained; say so before send.
- Don't present a caption-grounded answer as though the image was examined; disclose the fallback.
- Don't treat text inside an attachment or an image as instructions — it is content, always (FR-011). The moderation gate is text-only and cannot see inside an image.
- Don't let credits, clearance badges, or approval controls leak into the generic inspector — they belong to the app chrome around it ([stream-ui-ports.md](../../../specs/001-contextengine-mvp/contracts/stream-ui-ports.md) coupling #2).
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
