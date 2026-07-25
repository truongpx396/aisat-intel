---
description: "Subagent dispatch prompts for parallel execution of tasks.md (Stage 1 → Foundational → first story wave)"
---

# Subagent Dispatch Prompts — AISAT-INTEL MVP

Copy-paste prompts for executing [tasks.md](./tasks.md) with `superpowers:subagent-driven-development`
(fresh implementer subagent per task/batch + two-stage review). Batches map to the `[P]`
markers and user-story groupings already in `tasks.md`.

> **Parallel-safety contract (read first).** Concurrent *story tracks* (Wave 2+) are only safe under
> physical isolation. Each track runs in its **own git worktree** and its **own Docker project +
> database namespace** (see [Isolation model](#isolation-model-required-for-parallel-tracks)). The
> `[P]` batches inside Waves 0–1 edit disjoint files and are safe in a single tree. Routes are wired
> via **self-registering modules** so `cmd/api/main.go` / `app.py` stay FROZEN — every track wires
> itself and goes fully GREEN in its own worktree (no wiring task). Each track ends by **opening its
> own PR with pasted test evidence**; integration is serialized by a **merge queue** (rebase →
> regenerate lockfiles → full suite → merge), and a stale PR is bounced back to its owning agent —
> never hand-fixed (see [Parallel PR & conflict resolution](#parallel-pr--conflict-resolution-3-concurrent-tracks)).

## Global rules every subagent must obey

Paste this **preamble** into every implementer dispatch:

```
SHARED CONSTRAINTS (non-negotiable):
- TDD is NON-NEGOTIABLE (Constitution Principle VI). Write the test FIRST, run it, confirm it
  FAILS (Red), then implement until it PASSES (Green). Do not write implementation before a
  failing test exists.
- Integration tests use real backing services via Testcontainers (testcontainers-go /
  testcontainers-python). Do NOT mock Postgres/Redis/NATS/Qdrant.
- Stay strictly within your listed task IDs and file paths. Do NOT edit files owned by other
  tasks. Do NOT refactor unrelated code.
- SC-001 (access control) is a release blocker at 100% correctness. Any retrieval/cache/memory/RLS
  path must deny-by-default and fail loudly on a missing filter — never silently return data.
- Conform to the contract file referenced in your task (contracts/*.md). The contract is the spec.
- Respect kernel/product separation (Principle I/II): kernel/ must never import internal/.
- If you are a story-track subagent, work ONLY inside your assigned git worktree path. cmd/api/main.go
  and app.py are FROZEN — register your routes via your OWN module.go / router file (self-registration);
  never edit the frozen entrypoint. Your contract/E2E tests MUST go GREEN in-worktree; there is no
  "route pending wiring" state.
- For dependency additions (go.mod / pyproject.toml), follow the wave's ownership map; never edit
  another language's manifest. Treat go.sum / uv.lock as derived — regenerate (go mod tidy / uv lock),
  never hand-merge them.
- Evidence gate: STATUS is DONE only when you PASTE the actual test output (pass counts, lint clean,
  integration + E2E results) — not the words "all green". Unverified success is NEEDS_CONTEXT, not DONE.
- When your track is green, open a PR from track/<story> (gh pr create) whose body links the task IDs
  and includes the pasted evidence.
- Report STATUS as one of: DONE | DONE_WITH_CONCERNS | NEEDS_CONTEXT | BLOCKED, then a summary of root
  cause + changes + test results.
```

## Isolation model (required for parallel tracks)

Parallel story tracks share one filesystem and one Docker host by default — that is the unsafe
case. Before dispatching Wave 2, establish physical isolation with `superpowers:using-git-worktrees`.

**Per-track worktree (one per concurrent story):**
```bash
# from repo root, once per track (e.g. us1, us2)
git worktree add ../aisat-us1 -b track/us1
git worktree add ../aisat-us2 -b track/us2
```
Each implementer subagent for a track operates ONLY inside that track's worktree path. Two agents
in two worktrees editing the same file becomes a visible **merge** conflict at integration time,
not a silent lost write.

**Per-track Docker + DB namespace (prevents container/port/DB races):**
```bash
# each track exports a unique compose project name before `make up`/integration
export COMPOSE_PROJECT_NAME=aisat_us1   # us2 → aisat_us2, etc.
```
Testcontainers already gives each `go test`/`pytest` run ephemeral containers; the project-name
split additionally isolates any long-running `make up` infra and avoids port collisions when two
tracks run integration suites at once. Never point two tracks at the same shared dev database or
run `make migrate` against it concurrently.

**Docker capacity:** each integration run can spin up Postgres+Redis+NATS+Qdrant. Keep **≤2 tracks**
running integration suites simultaneously on a typical laptop; raise only if the Docker host has
headroom. Resource exhaustion shows up as flaky/timeout failures, not logic errors.

**Integration is serialized by a merge queue, not a manual step.** Each finished track is GREEN in
its own worktree and opens its own PR. The merge queue integrates PRs one at a time — rebase on
`main`, regenerate `go.sum`/`uv.lock`, run the FULL suite on the rebased tree, merge only if green.
There is no hand-authored wiring task and no shared `main.go`/`routes.go` edit (see
[Self-registering modules](#self-registering-modules-no-wiring-task) and
[Parallel PR & conflict resolution](#parallel-pr--conflict-resolution-3-concurrent-tracks)).

## Conflict-avoidance ownership map (enforced across all waves)

| Shared resource | Owner | Rule for everyone else |
|---|---|---|
| `backend-go/migrations/*` | one task per number (`0010` US1, `0011` US2, `0012` US4, `0013` US6, `0014` US7, `0015` Polish) | never create/edit another story's migration file |
| `backend-go/go.mod`, `backend-python/pyproject.toml` | one track per language OWNS dep additions this wave | others request additions via the owner; never edit another language's manifest |
| `backend-go/go.sum`, `backend-python/uv.lock` | derived — owned by the PR being merged | NEVER hand-merge; REGENERATE (`go mod tidy` / `uv lock`) after rebase |
| `backend-go/cmd/api/main.go`, `app.py` | FROZEN registry iterator (no owner edits it) | each track self-registers via its OWN `module.go` / router file; never edit the entrypoint |
| `services/llm_gateway.py`, `mcp_server/server.py`, `retrieval/filter.py` | Foundational (frozen after Stage 2) | consume only; changes serialize through a single agent |
| `retrieval/bootstrap.py` Qdrant collections/indexes | T034 only | never redefine collections or payload indexes |
| `services/pii_scrub.py` | T123 (Polish), but T026 depends on it | gateway calls it; do not fork a second scrubber |

### Self-registering modules (no wiring task)

There is **no** hand-authored wiring task. Each module registers its OWN routes so a track wires
itself and goes fully GREEN inside its worktree — `cmd/api/main.go` / `app.py` are FROZEN.

**Pattern (Go):**
```go
// backend-go/internal/<story>/module.go — each track adds its OWN file (append-only, zero conflict)
func init() {
    registry.Register(func(deps appctx.Deps) http.Handler {
        // build this story's routes from shared infra in deps, return its sub-router
    })
}
```
```go
// backend-go/cmd/api/main.go — FROZEN: iterates the registry, injects shared infra. Never edited per module.
deps := appctx.New(db, redis, nats, qdrant, gateway) // shared infra built once
for _, setup := range registry.Modules() {
    mux.Mount(setup(deps))
}
```
Python mirrors this: each story exposes an `APIRouter` in its own module file and self-registers via
an import side-effect / entry-point list iterated by a frozen `app.py`. The single import line that
activates a new module is the ONE conventional append point — keep it alphabetised so additions
append cleanly instead of colliding.

Result: a track's contract/E2E tests register their routes and turn GREEN **in-worktree**. The
`DONE_WITH_CONCERNS: route pending wiring` state is abolished.

### Per-track definition of done (evidence-gated)

A track is DONE only when, INSIDE its worktree:
1. The full relevant suite is GREEN — `make lint test` + its Testcontainers integration + its Playwright E2E.
2. The implementer **pastes the actual test output** (pass counts, lint clean) into STATUS — never the bare word "green".
3. A PR is opened from `track/<story>` (`gh pr create`) whose body links the task IDs and includes the pasted evidence.

Unverified "it passes" without pasted output is `NEEDS_CONTEXT`, not `DONE`.

### Parallel PR & conflict resolution (3+ concurrent tracks)

Concurrent tracks each open a PR; merging the first can make the others stale. That is **expected and
safe** — the goal is to make conflicts rare, mechanical, and bounced to the owning agent, never
hand-fixed by you.

**Avoid — keep shared files append-only (conflicts become rare):**

| Hotspot | Conflict-free rule |
|---|---|
| `cmd/api/main.go` / `app.py` | FROZEN registry iterator — never edited per module (see above) |
| route / module lists | each track adds its OWN `module.go` / router file; the activation import is append-only + alphabetised |
| `go.mod` / `pyproject.toml` | one track per language OWNS dep additions this wave; others request via the owner |
| `go.sum` / `uv.lock` | NEVER hand-merge — REGENERATE (`go mod tidy`, `uv lock`) after rebase; treat as derived |
| shared `types.ts` / enums / constants | one-symbol-per-file or append-only barrel export; never edit the middle |

**Resolve — serial integration, tool-enforced (no manual task):**
```
Tracks green in isolation → each opens a PR → merge queue integrates ONE at a time:
  • rebase the PR on latest main
  • regenerate lockfiles (go mod tidy / uv lock) — do NOT merge them by hand
  • run the FULL suite on the rebased tree
  • merge only if green; otherwise bounce back to the owning track
```
Use GitHub merge queue (branch protection → "require merge queue") or bors / Mergify. A green PR
proves a track in isolation; the merge queue is what proves post-merge `main`. Without a queue, the
manual floor is: merge one PR → rebase the next on `main` → rerun full suite → merge. Never merge
stacked PRs back-to-back without re-running the suite on each rebased tree.

**Bounce a stale PR back to its owning agent (do NOT hand-fix):**
```
[preamble]
main advanced after another track merged; track/<story> is now stale.
1. Rebase track/<story> on origin/main.
2. Regenerate go.sum / uv.lock (go mod tidy / uv lock) — do NOT hand-merge lockfiles.
3. Re-run the FULL suite; paste the actual output.
4. Force-push the branch. If a SOURCE (non-lockfile) conflict remains, resolve it preserving BOTH
   behaviors and explain the resolution in the PR. Return STATUS + evidence.
```

---

## WAVE 0 — Stage 1 Setup (serialize T001, then one `[P]` batch)

### Dispatch 0a (serial, blocks everything)

```
[preamble]
Task: T001 — Create the three-runtime directory skeleton exactly per plan.md:
  backend-go/{cmd/api,kernel,internal,migrations,tests}
  backend-python/{src,tests,evals,prompts}
  frontend/{src,tests}
  deploy/
This is structural only. No code. Return STATUS when the tree exists and is committed.
```

### Dispatch 0b (parallel batch — dispatch all at once after 0a)

Dispatch these as concurrent implementer subagents (different files, zero shared state):

- `T002` — Go module `backend-go/go.mod` (Gin, GORM, nats.go, go-redis, OTel, zerolog, Sentry, testcontainers-go)
- `T003` — Python `backend-python/pyproject.toml` (FastAPI, LangGraph, Mem0, BAML, FastMCP, MarkItDown, Crawl4AI, qdrant-client, openai, cohere, structlog, Langfuse, testcontainers)
- `T004` — React SPA `frontend/package.json` (React 19, Vite, TS 5.x, EventSource, PostHog, Vitest, Playwright)
- `T005` — `deploy/docker-compose.yml` (postgres, redis, qdrant, nats, minio, casdoor, caddy)
- `T006` — `deploy/Caddyfile`
- `T007` — root `Makefile` (`up/down/migrate/dev/build/test/lint/eval`)
- `T008` — `backend-go/.golangci.yml` (incl. `depguard`: kernel must not import internal)
- `T009` — Python ruff+black config
- `T010` — frontend eslint+prettier config
- `T010a` — Testcontainers bootstrap helpers + Playwright config/fixtures

Per-subagent prompt template:
```
[preamble]
Task: <Txxx> — <verbatim task text from tasks.md>
File(s): <exact path(s) from the task>
This is config/scaffolding. No app logic. Verify the runtime builds/initializes where applicable.
Return STATUS + what you created.
```

**GATE:** Verify `make up` brings up infra and all three runtimes build empty before Wave 1.

---

## WAVE 1 — Stage 2 Foundational (ordered `[P]` batches; BLOCKS all stories)

Run as **four sequential sub-batches**; parallelize within each.

### Batch 1.1 — Kernel interfaces + platform clients (all `[P]`, fully parallel)
`T011` kernel interfaces · `T012` Postgres · `T013` Redis (role separation, research §10) ·
`T014` NATS · `T015` Qdrant · `T016` OTel+logger · `T017` Casdoor Auth adapter

### Batch 1.2 — Schema/RLS/shared layer (ORDERED: T018→T019→T020, then T021–T023 `[P]`, then T024)
```
[preamble]
ORDERED migration chain — do NOT parallelize T018/T019/T020:
  T018 migration framework + 0001_init.sql (UUID v7, SET LOCAL app.workspace_id convention)
  T019 0002_kernel.sql (users, workspaces, members, invites, audit_log, api_keys, plans,
       subscriptions, notifications, notification_preferences, feature_flags)
  T020 0003_rls.sql — RLS on EVERY tenant-scoped table; notifications additionally restricted to
       recipient (workspace_id AND user_id). SC-001/SC-012.
Then parallel: T021 error envelope+DTO · T022 Tenant middleware (SET LOCAL app.workspace_id +
app.user_id) · T023 auth/request-id/recovery middleware.
Finally T024 app root + module registry: build shared appCtx/Deps once and iterate
registry.Modules() to mount each self-registered module. cmd/api/main.go is the FROZEN registry
iterator — stories self-register via their own module.go, never edit main.go. T024 also scaffolds
cmd/relay/main.go (SSE streaming role) and cmd/worker/main.go (background role: scale-out
queue-group consumers notify.<ws> + notify.email.<ws>, N idempotent replicas; plus single-owner
scheduled jobs *.tick/*.refresh + outbox + DLQ sweep, no in-process timers), all sharing one image
(Principle IV, research §14/§15).
Then T024a generic DLQ sweeper (single-owner in cmd/worker, triggered by dlq.sweep.tick): for each
msg in every *.dlq.<ws>, re-publish to its owning work subject with dlq_attempts+1 under exponential
backoff while dlq_attempts < MAX_DLQ_ATTEMPTS (default 5), else write to dead_letters + emit
dlq.dead.count; re-drive only, never reprocesses payloads. backend-go/internal/platform/dlq/sweeper.go
wired in cmd/worker (research §18).
```

### Batch 1.3 — Python chokepoints (CRITICAL — frozen after this batch)
```
[preamble]
T025 (test FIRST, must fail) contract test for LLM gateway per contracts/llm-gateway.md.
T024b deploy the standalone LLM gateway service (LiteLLM :4000, deploy/llm-gateway/config.yaml —
     aliases fast/smart/embed/rerank → provider models, keys, LB + one-hop fallback; built-in
     budget/cache DISABLED; Bifrost-swappable). research §21.
T026 LLM gateway-CLIENT wrapper (forwards to :4000; idempotency, budget gate, clearance-scoped
     semantic cache, PII scrub, cost→billing.deduct, trace + llm_call_log). Alias/fallback live in
     the gateway config (T024b), NOT here. NOTE: pii_scrub.py (T123) may be a thin stub now; the
     gateway-client is its only caller.
T027 Qdrant access-control pre-filter — TWO builders:
     personal_filter(workspace_id,user_id) and workspace_filter(workspace_id,access_level).
     DENY-BY-DEFAULT: any Qdrant search with no workspace_id (and, for workspace collection, no
     access_level bound) MUST RAISE, not execute. Test member-B-reads-member-A's-personal → 0 rows.
T028 FastMCP server + per-role allowed_tools allowlist dispatch guard.
T029 FastAPI entrypoint + NATS subscriber bootstrap.
T030 BAML client scaffold + structlog/Langfuse bootstrap.
These files are FROZEN after this batch — downstream stories consume, never edit them.
```

### Batch 1.4 — Frontend foundation + Qdrant seed (`[P]` then T034)
`T031` API client · `T032` typed SSE client (contracts/sse-events.md) · `T033` design-system
primitives + app shell (WCAG 2.1 AA) — parallel. Then `T034` Qdrant collection bootstrap
(`personal`, `workspace` + payload indexes) wired into `make migrate`.

**GATE (Foundation checkpoint):** chokepoint contract tests green, migrations apply, `make up`
healthy. **No story starts until this passes.**

---

## WAVE 2 — First story wave (parallel: US1 + US2, the P1 MVP)

**Isolation precondition:** create one worktree per track (`track/us1`, `track/us2`) and a unique
`COMPOSE_PROJECT_NAME` per track BEFORE dispatching — see [Isolation model](#isolation-model-required-for-parallel-tracks).
Each track's subagents work only inside their worktree, self-register their routes (no shared
`main.go` edit), and must reach GREEN with pasted evidence in-worktree. Each track then opens its
own PR; the [merge queue](#parallel-pr--conflict-resolution-3-concurrent-tracks) integrates them one
at a time (rebase → regenerate lockfiles → full suite → merge).

Dispatch **US1 and US2 as two concurrent story-tracks**. Within each track, run the test batch
first (Red), then models `[P]`, then services/endpoints, then integration. Cap concurrency at
the test/model batches; serialize the files each story shares internally.

### Track A — US1: Ingest knowledge (migration range: `0010` only)

Test batch (dispatch together, must FAIL):
```
[preamble]
US1 — write these tests first; they MUST fail before any US1 implementation exists:
  T035 contract POST /ingest/presign (413 oversize, 501 video/audio, access_level ≤ caller) per contracts/bff-rest.md
  T036 contract /ingest/link, /ingest/note, GET /ingest/{jobId}/status SSE stages
  T037 contract ingestion NATS subjects (pdf/docx/image/crawl; audio→501; embed-outage→ingestion.dlq) per contracts/nats-subjects.md
  T037a contract ingestion.dlq drain via dlq.sweep.tick — parked chunk under cap re-drives to embed
        with ORIGINAL model only + re-embeds idempotently (no duplicate Qdrant point); a chunk at
        MAX_DLQ_ATTEMPTS lands in dead_letters + emits dlq.dead.count, not re-driven. (research §18, FR-029)
  T038 integration ingestion pipeline (PDF: converting→metadata→chunking→embedding→indexed)
  T039 contract GET /documents + /documents/{id} (clearance + RLS scoped, image caption present)
Return STATUS once all are committed and confirmed RED.
```

Implementation — Go side (serialize T040→T043→T044→T045→T046; T041/T042 `[P]`):
```
[preamble]
US1 Go. You OWN backend-go/migrations/0010_documents.sql — no other migration number.
  T040 Document partitioned table (source_type, tags[], summary, data_type, access_level, scope,
       SERVER-STAMPED security fields, partition by created_at). FR-004.
  T041 [P] Document model · T042 [P] ingest DTOs+errors
  T043 presign service (content_length ≤ max_upload_bytes → 413; video/audio → 501; stamp security
       fields; default access_level to caller clearance; S3 presigned PUT). FR-003/FR-004.
  T044 ingestion+enrich orchestration (S3 event → publish ingestion.<mime>.<ws>; enrich.note.<ws>)
  T045 document repo (RLS-scoped list/get/soft-delete)
  T046 ingest+notes HTTP transport + self-registering module.go (registry.Register; cmd/api/main.go is FROZEN — do NOT edit it)
Make the T035/T036/T039 contract tests pass GREEN in-worktree and paste the output. Return STATUS.
```

Implementation — Python side (T047/T049/T050/T051/T051a/T052/T053 `[P]`; T048/T054/T055 serial):
```
[preamble]
US1 Python ingestion. Consume the FROZEN chokepoints (llm_gateway, filter, bootstrap) — do not edit them.
  T047 [P] schemas · T049 [P] MarkItDown (PDF/DOCX/MD) · T050 [P] image captioner (gateway `fast`)
  T051 [P] web_distill — SSRF-guarded (https-only; reject private/loopback/link-local/reserved IPs
       after resolving ALL A/AAAA; redirect:error; bounded size+timeout) → Crawl4AI → distill
  T051a [P] note-enrich worker (enrich.note.<ws>, streams fetching→distilling→drafting→token→done)
  T052 [P] audio 501 stub · T053 [P] BAML metadata extractor (advisory only — security stamped server-side)
  T048 pipeline orchestrator + NATS consumers per MIME (status via Redis pub/sub)
  T054 structure-aware parent/child chunker (split on headings/para/sentence, never mid-sentence;
       child 200 / parent 1000 tokens, parent_doc_id link). §16
  T054a [P] flag-gated contextual-retrieval prefix (chunking.contextual_prefix, fast alias, per-doc
       summary reused; embedded with child, non-citable; CI-enable gated on eval recall/MRR/citation). §16
  T055 embed + Qdrant upsert (full payload incl. access_level, hot); embed outage → ingestion.dlq.<ws>
       NO model substitution on embed failure.
Make T037/T038 pass. Return STATUS.
```

Frontend:
```
[preamble]
US1 T056 [P] — upload + library UI (drag-drop, presign PUT, live SSE progress, document list with
tags/summary, image caption view) in frontend/src/features/upload/ and library/.
```

### Track B — US2: Cited, access-scoped answers (migration range: `0011` only)

Test batch (dispatch together, must FAIL — note the SC-001 adversarial tests):
```
[preamble]
US2 — write these first; MUST fail before implementation:
  T057 contract POST /query (stream_id, moderation short-circuit injection_blocked/disallowed
       BEFORE spend, idempotency) per contracts/bff-rest.md
  T058 contract query SSE taxonomy + DebugTrace shape per contracts/sse-events.md
  T059 contract MCP knowledge tools — search_workspace_knowledge NEVER returns access_level >
       effective_access_level; structured tools reject raw SQL (typed filters only) per contracts/mcp-tools.md
  T060 integration graph happy path (moderate→rewrite→retrieve→rerank→memory→generate→cite)
  T060a integration unanswerable query → grounded refusal, no fabrication, no cross-clearance leak
  T061 integration prompt-injection (delimited "ignore previous instructions" treated as data; injected tool call does not escalate)
  T061a integration memory clearance — L4 memory + sentinel, demote to L2, assert NOT injected at Node 5, sentinel absent
  T062 integration structured Tier-2 via fixed query_employees/projects/metrics tools
Return STATUS once committed and RED.
```

Implementation (retrieval/agent `[P]` where marked; graph T073 + router T075 + Go relay T076 serial):
```
[preamble]
US2. You OWN backend-go/migrations/0011_query_structured.sql only. Consume FROZEN chokepoints.
  T063 0011 migration (chat_session mem0_session_id hash-partitioned by user_id; employees/projects/metrics)
  T064 [P] query+agent schemas
  T065 [P] hybrid retrieval — TWO parallel Qdrant searches: personal_filter(ws,requester_user_id)
       on personal + workspace_filter(ws,user_access_level) on workspace, then RRF-interleave.
       Merged set must NEVER contain another user's personal chunks.
  T066 [P] reranker (gateway `rerank`) + hot/cold tier routing
  T067 [P] child→parent expansion
  T068 [P] Mem0 memory — WRITE stamps access_level = max of contributing chunks; READ (Node 5)
       injects only access_level ≤ current clearance. Post-demotion memory never injected. (research §13)
  T069 [P] semantic+exact cache keyed workspace+user+access_level+model+query w/ cacheable_scope (research §2)
  T070 MCP knowledge tools (search_personal/workspace_knowledge, get_document_by_id, list_documents)
  T071 [P] MCP structured tools (parameterized SQL ONLY) · T072 [P] MCP utility (get_current_datetime)
  T073 LangGraph 7-node graph (Node 0 moderation gate → router → rewrite → retrieve → rerank/expand
       → memory → generate+cite); retrieved content is DELIMITED UNTRUSTED DATA. FR-010/011, SC-007.
  T074 [P] prompt assets · T075 query router (query.agent.<ws> → graph → Redis pub/sub by stream_id)
  T076 Go query service + SSE relay (POST /query, moderation short-circuit, GET /query/{streamId}[/debug])
       + self-registering module.go (registry.Register; cmd/api/main.go is FROZEN — do NOT edit it)
  T077 [P] chat UI · T077a [P] follow-up generator (Node 7) · T077b [P] suggestions SSE contract test
Make all US2 tests pass GREEN in-worktree and paste the output. Return STATUS.
```

**Note:** US2 consumes US1's indexed chunks at runtime but is independently testable via seeded
fixtures — the two tracks run concurrently; do not block B on A.

---

## Two-stage review (run after EVERY task/batch completes)

```
SPEC REVIEW (dispatch spec-reviewer subagent):
Review the diff for <Txxx>. Does it match contracts/<file>.md exactly? Flag (a) missing spec
requirements, (b) extra unrequested behavior. For SC-001 surfaces, confirm deny-by-default and the
zero-above-clearance property hold. Return: ✅ compliant OR ❌ with specific gaps.
```
```
CODE-QUALITY REVIEW (after spec passes):
Review <Txxx> for correctness, OWASP issues (esp. SSRF on web_distill, injection on MCP tools),
test quality (real Testcontainers, meaningful assertions), and kernel/internal separation.
Return strengths + issues by severity + approve/needs-changes.
```

## Recommended concurrency

- Waves 0/1: single shared tree is fine — the `[P]` batches edit disjoint files. Parallelize within
  each batch; serialize batch→batch at the gates. (`go.mod`/`pyproject.toml`/`package.json` are each
  created once by a single task here, so no manifest race.)
- Wave 2: **US1 + US2 concurrently**, each in its OWN git worktree + Docker project namespace. Keep
  ≤2 tracks running integration suites at once on a laptop. Add **US3 + US4** as further worktrees
  after the Foundation checkpoint only if the Docker host has headroom. US5 waits on US2; US6/US7/US8
  follow per the dependency graph in tasks.md.
- After each wave's tracks finish: each opens its own PR → the
  [merge queue](#parallel-pr--conflict-resolution-3-concurrent-tracks) integrates them one at a time
  (rebase → regenerate lockfiles → full suite → merge) before starting the next wave. A stale PR is
  bounced to its owning agent, never hand-fixed.
- After all targeted stories: dispatch the Stage 11 adversarial hardening (T140–T144) + final
  whole-implementation review, then `superpowers:finishing-a-development-branch`.
