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
- **Ingestion progress row**: per-item live status using a status pill — `queued` → `converting` → `captioning` (images) → `embedding` → `ready` / `failed`. Streamed via SSE. Include a thin determinate/indeterminate progress bar.
- **Document card**: title, source-type icon (note icon for notes), auto-summary (2 lines, muted), auto-taxonomy tag chips, a **clearance badge (L1–L5)**, owner avatar, and a relative timestamp. A note card surfaces its **source-link citations** (favicon/host chips). Card is `.card--interactive`.
- **Access-level selector** (on upload/note): dropdown limited to ≤ uploader's own clearance; defaults to the uploader's clearance when unset (FR-004). Never offer a level above the user's clearance.
- **Oversize/error toast**: clear boundary rejection message for files over the workspace limit.

## States to show
- Empty library (first run) with an inviting dropzone.
- Note composer with attached links, mid-enrich (draft panel streaming) and the draft-review state (Accept / Discard / Re-enrich).
- Active ingestion with 2–3 items at different stages.
- Populated grid with varied types (incl. notes with citation chips), tags, and clearance badges.

## Don'ts
- Don't show documents above the viewer's clearance.
- Don't let access-level options exceed the uploader's clearance.
- Don't index or library-surface an enrichment draft before the member accepts it.
- Don't auto-run Enrich on save — it spends credits and must be member-initiated.
