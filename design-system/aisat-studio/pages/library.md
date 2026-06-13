# Page Override: Library (Ingest & Browse)

> Overrides `../MASTER.md` for the Library screen. Covers User Story 1 (FR-001…FR-005).

## Purpose
The entry point: members upload files / paste links / add notes, watch live ingestion
progress, then browse the searchable, auto-tagged knowledge library.

## Layout
- App shell (persistent sidebar + top bar) from MASTER. Active nav = **Library**.
- Two-zone content:
  1. **Ingest bar** (top): drag-and-drop dropzone + "Paste link" + "New note" actions, and a per-file size hint (default 50 MB).
  2. **Library grid** (below): card grid of documents with filters (type, tag, clearance, status) and a search field.

## Key components
- **Dropzone**: dashed `--color-border` border, run-green on drag-over. Shows accepted types (PDF, DOCX, MD/TXT, image) and the size limit. Unsupported types (video/audio) show an inline "not supported yet" message, not a silent failure (FR-003).
- **Ingestion progress row**: per-item live status using a status pill — `queued` → `converting` → `captioning` (images) → `embedding` → `ready` / `failed`. Streamed via SSE. Include a thin determinate/indeterminate progress bar.
- **Document card**: title, source-type icon, auto-summary (2 lines, muted), auto-taxonomy tag chips, a **clearance badge (L1–L5)**, owner avatar, and a relative timestamp. Card is `.card--interactive`.
- **Access-level selector** (on upload): dropdown limited to ≤ uploader's own clearance; defaults to the uploader's clearance when unset (FR-004). Never offer a level above the user's clearance.
- **Oversize/error toast**: clear boundary rejection message for files over the workspace limit.

## States to show
- Empty library (first run) with an inviting dropzone.
- Active ingestion with 2–3 items at different stages.
- Populated grid with varied types, tags, and clearance badges.

## Don'ts
- Don't show documents above the viewer's clearance.
- Don't let access-level options exceed the uploader's clearance.
