# Track Manifest — AISAT-STUDIO MVP (001-contextengine-mvp)

Consumed by the `executing-parallel-tracks` skill. Task IDs, ownership, and isolation rules are
derived from [tasks.md](./tasks.md) and [dispatch-prompts.md](./dispatch-prompts.md). When those
files change, update this manifest.

## Defaults

- **default_branch**: `main`
- **worktree_root**: `..` (e.g. `../aisat-us1`)
- **docker_namespace_pattern**: `aisat_<track_id>` (exported as `COMPOSE_PROJECT_NAME`)
- **max_concurrent_tracks**: `2`  <!-- laptop Docker cap; each track may spin Postgres+Redis+NATS+Qdrant -->
- **runs_dir**: `runs/` (git-ignored; run records + summary.md live here)

## Hard stops (orchestrator-enforced)

- **self_heal_attempts**: `2`
- **max_iterations**: `25`
- **no_progress_passes**: `3`
- **per_worker_budget_usd**: `5`
- **global_budget_usd**: `20`

## Commands

| Purpose | Command |
|---|---|
| lint | `make lint` |
| unit test | `make test` |
| integration test | `go test -tags=integration ./...` · `pytest -m integration` |
| e2e | `npx playwright test` |
| regenerate Go lockfile | `go mod tidy` |
| regenerate Python lockfile | `uv lock` |
| open PR | `gh pr create --fill --base main` |

## Frozen entrypoints (self-registration required)

- `backend-go/cmd/api/main.go` — FROZEN registry iterator; builds shared `Deps` once and mounts each `registry.Modules()`. Stories add their own `backend-go/internal/<story>/module.go` (`registry.Register`).
- `backend-python/src/app.py` — FROZEN; iterates the per-story `APIRouter` list. Stories self-register via their own router module.

## Ownership map (shared resources)

| Shared resource | Owner | Rule for everyone else |
|---|---|---|
| `backend-go/migrations/*` | one task per number (US1 `0010`, US2 `0011`, US4 `0012`, US6 `0013`, US7 `0014`, Polish `0015`) | never create/edit another story's migration file |
| `backend-go/go.mod`, `backend-python/pyproject.toml` | one track per language owns dep additions this wave | others request via owner; never edit another language's manifest |
| `backend-go/go.sum`, `backend-python/uv.lock` | the PR being merged | NEVER hand-merge — regenerate (`go mod tidy` / `uv lock`) after rebase |
| `backend-go/cmd/api/main.go`, `backend-python/src/app.py` | FROZEN registry iterators | self-register via own module/router file; never edit the entrypoint |
| `services/llm_gateway.py`, `mcp_server/server.py`, `retrieval/filter.py`, `retrieval/bootstrap.py` | Foundational (frozen after Stage 2) | consume only; never edit |

## Invariants to assert in review

- **SC-001 access control** — every retrieval/cache/memory/RLS path denies-by-default and fails loudly on a missing filter; search results NEVER exceed caller clearance (zero-above-clearance). Release blocker at 100%.
- **Kernel/product separation** (Principle I/II) — `kernel/` must never import `internal/`.
- **LLM single chokepoint** (Principle IV) — all model calls go through `llm_gateway.py`; no direct provider calls.
- Retrieved/external content is DELIMITED UNTRUSTED DATA (prompt-injection defense, SC-007).

## Tracks

```yaml
tracks:
  - id: us1                       # Ingest knowledge (P1 MVP)
    branch: track/us1
    worktree: ../aisat-us1
    tasks: [T035, T036, T037, T038, T039, T040, T041, T042, T043, T044, T045, T046,
            T047, T048, T049, T050, T051, T051a, T052, T053, T054, T054a, T055, T056]
    owns_migrations: ["0010"]
    depends_on: []

  - id: us2                       # Cited, access-scoped answers (P1 MVP)
    branch: track/us2
    worktree: ../aisat-us2
    tasks: [T057, T058, T059, T060, T060a, T061, T061a, T062, T063, T064, T065, T066,
            T067, T068, T069, T070, T071, T072, T073, T074, T075, T076, T077, T077a, T077b]
    owns_migrations: ["0011"]
    depends_on: []               # consumes US1 chunks at runtime, but independently testable via seeded fixtures
```

> **Precondition:** Wave 1 (Foundational, Stage 2) must be green — chokepoint contract tests
> passing, migrations applied, `make up` healthy — before any track here starts.
