# Page Override: Library (Ingest & Browse)

> Overrides `../MASTER.md` for the Library screen. Covers User Story 1 (FR-001…FR-005).

## Purpose
The entry point: members upload files or write notes (optionally attaching web links
that enrich the note on demand), watch live progress, then browse the searchable,
auto-tagged knowledge library.

## Layout
- App shell (persistent sidebar + top bar) from MASTER. Active nav = **Library**.
- Two-zone content:
  1. **Ingest bar** (top): drag-and-drop dropzone + "New note" action, and a per-file size hint (default 50 MB). Pasting a bare URL is accepted as a shortcut that opens a new note pre-filled with that link.
  2. **Library grid** (below): card grid of documents with filters (type, tag, clearance, status) and a search field.

## Key components
- **Dropzone**: dashed `--color-border` border, run-green on drag-over. Shows accepted types (PDF, DOCX, MD/TXT, image) and the size limit. Unsupported types (video/audio) show an inline "not supported yet" message, not a silent failure (FR-003).
- **Note composer**: a body text area plus an **attached-links** list (add/remove URLs). Primary action **Enrich** (disabled until at least one link is attached) and **Save** (saves the note as-is). Enrich is re-runnable.
- **Enrich draft panel**: opens when Enrich runs. Shows live stages via SSE — `fetching` → `distilling` → `drafting` → streaming draft tokens. A link that fails (SSRF/fetch) is shown as a skipped chip; one bad link never fails the whole draft. The draft is a **proposal**: actions **Accept** (persists the note body + source citations, then runs normal ingestion), **Discard**, and **Re-enrich**. Nothing is indexed until Accept (human-in-the-loop, FR-012).
- **Agent note-edit review panel** *(FR-041, human-in-the-loop)*: when an agent proposes an edit to an existing note (the `edit_note` action tool), it surfaces here as a review — a **red/green line diff** of the proposed `body`, the acting agent's name + effective clearance (`min(agent, owner)`), and actions **Approve** (applies the edit + re-indexes), **Edit & approve** (correct the text first), and **Reject** (leaves the note unchanged). Same accept-gate shape as the Enrich draft panel; nothing changes on the note until Approve. Reachable from the notification deep-link, the Agents activity view, and a badge on the note card. If the edit is out of the agent's scope (above clearance / would raise the note's level / a create attempt) it never appears as an applied change — the denial reason is shown instead (FR-041, SC-015).
- **Ingestion progress row**: per-item live status using a status pill — `queued` → `converting` → `captioning` (images) → `embedding` → `ready` / `failed`. Streamed via SSE. Include a thin determinate/indeterminate progress bar.
- **Document card**: title, source-type icon (note icon for notes), auto-summary (2 lines, muted), auto-taxonomy tag chips, a **clearance badge (L1–L5)**, owner avatar, and a relative timestamp. A note card surfaces its **source-link citations** (favicon/host chips). Card is `.card--interactive`.
- **Access-level selector** (on upload/note): options are generated from the workspace's `clearance_scheme` config and limited to ≤ uploader's own clearance; defaults to the uploader's clearance when unset (FR-004). Never offer a level above the user's clearance, and never hardcode a level name — a workspace running a 3-tier scheme sees three options with its own labels. The sharing-rule explainer beneath is generated from the same config, greying levels above the viewer's clearance.
- **Group restriction picker** *(Phase 2)*: optional multi-select of toggle chips directly beneath the access-level selector — the second access axis (see [specs/draft-plan.md](../../../specs/draft-plan.md) "Access model (decided)"). Only lists groups the uploader belongs to, mirroring the tag-up-to-your-own-level rule. Mirrored groups carry their source badge (`confluence`, `git`). Empty selection is the norm and means clearance alone governs.
- **Live visibility summary**: one line under the picker that resolves both axes into plain language — "Visible to: members with clearance **L3+** who are also in **security**". Two independent access axes are genuinely hard to hold in your head; without this line, users guess, and guessing about access controls is how documents get over-shared.
- **Group chip on document cards** *(Phase 2)*: group-restricted documents show a group chip next to the clearance badge, so restriction is visible when browsing, not just at upload time.
- **Oversize/error toast**: clear boundary rejection message for files over the workspace limit.

## Mind Map tab *(Phase 2)*
A renderer over persisted `knowledge_edges` — the Enterprise Knowledge Layer owns the edge
model, this tab draws it.
- **Seed bar**: seed from a topic string, a document, or a note; toolbar with **Expand**,
  **Collapse subtree**, **Save layout**, **Export**; a live node counter against the
  200-node cap.
- **Graph canvas**: node colour by kind (document/artifact, note, topic/entity), edge
  thickness by evidence weight, dashed stroke for `llm_inferred` edges vs solid for
  `declared_in_source`. A legend is mandatory — thickness and dash carry meaning that is
  otherwise invisible. SVG glyphs only, never emoji.
- **Inspector**: for the selected node/edge — kind, clearance, retrieval score, edge
  **provenance** and **confidence**, and the evidence snippet that produced the link, with
  **Open source** / **Expand**.
- **Debug panel**, consistent with the chat debug drawer: edge threshold, candidates kept,
  counts filtered by clearance *and* by group, whether label generation ran, credits spent.
- **Two standing notes**: no fabricated edges (every edge shows provenance + confidence),
  and nodes the viewer cannot access are **omitted, not greyed out** — a locked placeholder
  leaks that the document exists.

## States to show
- Empty library (first run) with an inviting dropzone.
- Note composer with attached links, mid-enrich (draft panel streaming) and the draft-review state (Accept / Discard / Re-enrich).
- Active ingestion with 2–3 items at different stages.
- Populated grid with varied types (incl. notes with citation chips), tags, and clearance badges.

## Don'ts
- Don't show documents above the viewer's clearance.
- Don't let access-level options exceed the uploader's clearance.
- Don't offer groups the uploader doesn't belong to — the picker is not a directory browser.
- Don't imply a group *widens* access. A doc tagged `L1` + `security` is **not** public; it is visible only to members of `security`. If the copy ever reads as "share with security", it is wrong — the axis restricts, it does not share.
- Don't index or library-surface an enrichment draft before the member accepts it.
- Don't auto-run Enrich on save — it spends credits and must be member-initiated.
- Don't apply an agent's proposed note-edit before the member approves it, and never show an agent edit as applied when it was out of the agent's access scope — show the denial, not a silent success (FR-041, SC-015).

---

## Phase 2+ affordances on this screen

| Affordance | Phase | Backing contract |
|---|---|---|
| Group restriction picker + live visibility summary | 2 | `documents.allowed_principals`; `principal_groups` |
| Group chip on document cards | 2 | same |
| Tab shell (**Documents** · **Mind Map**) | 2 | Surfaces & naming (decided) |
| Artifact type / origin / lifecycle facets | 2 | `documents` overlay columns |
| Mind Map tab | 2 | `knowledge_edges`; `POST /mindmap` + SSE |

**Why the Library, and not a separate Enterprise screen:** documents and typed artifacts
are the same `documents` table with an overlay. Splitting them across two destinations
would force a member to know whether a thing is a "document" or an "artifact" before they
could find it. The facets are how the typed layer surfaces; there is no second browser.
The **agent registry** is likewise a facet here (type = `agent_def`), not a second Agents
screen — the Agents nav item stays *runtime* (connected devices, running tasks). See
[specs/draft-plan.md](../../../specs/draft-plan.md) "Surfaces & naming (decided)".
