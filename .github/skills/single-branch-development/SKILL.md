---
name: single-branch-development
description: 'Run a full end-to-end implementation pipeline on one branch or worktree (TDD, two-stage verification for spec compliance plus code quality, evidence capture, optional Copilot hooks, and draft PR handoff). Use when asked to implement one feature or foundation setup with strong quality gates but without parallel fan-out orchestration.'
---

# Single-Branch Development

Run one autonomous branch from implement to review to evidence to draft PR. This skill is a thin
**per-branch bracket** around `subagent-driven-development` (SDD): it adds isolation *before* the
loop, an evidence gate *after* it, a draft-PR boundary that **replaces** SDD's merge-capable finish,
and the optional hooks bundle. It does **not** re-implement the implement/review loop — SDD owns
that. Use it standalone (N=1) or composed by a higher-level orchestrator.

## When to Use This Skill

- User asks to implement one feature end-to-end on a single branch.
- User asks for foundation/bootstrap work with strict gates before parallel tracks exist.
- You want TDD + verifier + evidence + draft PR without parallel fan-out complexity.
- You need a reusable per-branch worker contract that another skill can compose.

## Prerequisites

- `git` and `gh` CLI authenticated for PR creation.
- One or more tasks defined (a single task or a small plan that SDD can execute).
- Project test commands are known (lint/unit/integration/e2e as applicable).
- Optional: Copilot agent hooks enabled with a hook file in `.github/hooks/*.json`.

## Pipeline (One Branch)

This pipeline **brackets** `subagent-driven-development`; it never re-describes or re-runs SDD's
internal stages.

0a. **Preflight & Confirm (start gate).** Run [`scripts/track-preflight.sh`](scripts/track-preflight.sh)
   (`inspect` mode) before touching the repo. You only ever supply the **track slug** (e.g. *"do
   track `a`"* → `TRACK_ID=a`); the script settles identity and readiness off **one durable fact** —
   does a `runs/*.dispatch` breadcrumb for this `TRACK_ID` already exist?
   - **No breadcrumb → START (fresh).** Mints a stable `RUN_ID` = `<UTC-timestamp>_<track>` (you
     never invent or retype one), checks prerequisites, and on approval persists
     `runs/<RUN_ID>.dispatch`.
   - **Breadcrumb exists → RESUME (auto-detected).** Adopts *that* breadcrumb's `RUN_ID` and hands
     it to `track-reconcile.sh`. Breadcrumb-exists **is** the resume signal — there is no `--resume`
     flag; re-prompting the same slug resumes itself.

   It also checks prerequisites (git work tree, `runs/` writable, and — unless waived — `gh` auth +
   required toolchains), prints a one-screen summary (Mode · Track · Tasks · RUN_ID · Branch · Base
   ref · Prereqs · → Proceed?), and emits the same as JSON. **Confirm is optional** (an orchestrator
   passes `auto_confirm`/`--yes` to skip the human gate); a **prerequisite failure hard-fails in both
   modes**. On approval, re-run with `--commit` to persist the breadcrumb. Skip this step only when a
   caller already exported a known `RUN_ID`. See the [Gotchas](#gotchas) for the slug-reuse trap.
0b. **Reconcile / Resume (idempotent preflight).** Run
   [`scripts/track-reconcile.sh`](scripts/track-reconcile.sh) to rebuild position from **persisted
   state only** — committed history + `runs/<run-id>.json`, never the model's reading of the
   worktree. It reports `head`, `dirty_worktree`, and per-kind evidence as `fresh|stale|missing|failed`
   at the **current fingerprint** (reusing the evidence-gate's exact logic), self-recovering `RUN_ID`
   from the newest breadcrumb if none is exported. Then:
   - **(a)** if `dirty_worktree`, the uncommitted diff is *untrusted* — `git stash` it (reversible),
     never `git reset --hard` unfamiliar work or build on it.
   - **(b)** treat every `fresh` kind as proven-done and skip it.
   - **(c)** resume at the first task that is `missing`/`stale`/`failed`.

   The model's only decision is *which not-done task is next* — doneness stays mechanical
   (fingerprint match), never a judgement call. On a clean tree with nothing missing this is a no-op.
   Safe because setup tasks are idempotent (`go mod tidy`, `mkdir -p`, file creation replay cleanly).
1. **Isolate** — create/select one branch or worktree (`using-git-worktrees`). Never start on main.
2. **Delegate the implement → review loop to `subagent-driven-development`.** SDD owns the per-task
   engine, and this skill does **not** re-run or duplicate it. For each task SDD dispatches a fresh
   implementer subagent, then reviews its output in two stages — **stage 1** spec/contract compliance,
   **stage 2** code quality (the `requesting-code-review` rubric) — looping implementer↔reviewer until
   both stages pass. After the final task it runs one **whole-diff review** over the combined change.

   SDD's loop leaves **two gaps** that this skill treats as invariants you must close per task:
   - **Test-first is opt-in, so demand it.** SDD's implementer follows `test-driven-development` only
     "if the task says to." **Each implementation task's text must explicitly require TDD**, or
     test-first ordering is silently skipped.
   - **Stage 2 is quality-only, so add security.** The `requesting-code-review` rubric contains no
     security checks. For any change touching a trust boundary (input handling, auth, secrets, DB,
     network), the stage-2 reviewer must **also** apply `security-and-owasp.instructions.md`.
2b. **Freeze & verify-all (converge on one fingerprint).** Once the last task's review passes, make
   **no further edits**, then run *every* required evidence kind (`go-test`, `pg`, `redis`, …)
   back-to-back against the now-frozen tree so all captures share the **same** fingerprint. This
   isn't a second gate and it computes nothing new — the capture hook still stamps each run; the
   discipline is that no edit may follow, so the independent stamps *coincide* on the final tree.
   Any change after this — **including a review-driven fix** — invalidates the convergence and requires
   re-running all kinds. Skipping 2b is safe but wasteful: the gate will simply bounce stale lanes
   until you re-run them anyway. Doing it deliberately makes Step 3 a confirmation, not a catch.
3. **Evidence gate** (`verification-before-completion`) — paste real command output; "all green"
   without pasted output is not done.
4. **Update the run artifact** if your workflow tracks one (`runs/<run-id>.json`, handoff notes).
5. **Draft-PR finish (overrides SDD's terminal).** Open a **draft** PR and stop. This step
   **replaces** SDD's call to `finishing-a-development-branch` — the worker never reaches that
   skill's merge menu. Integration/merge is owned by repo process/CI, not the worker.

## Quality Gates (Owned Here)

These are the **invariants** this skill asserts; most are *realized by* SDD's loop, not re-run here.

- **TDD required** for implementation changes — but SDD's implementer applies it only when the task
  says so, so this skill's contract is that **every implementation task explicitly demands
  `test-driven-development`**. Nothing mechanically enforces test-first ordering (hooks can't see it);
  it is a prompt-level invariant, backstopped by the evidence gate requiring fresh passing tests.
- **Security review required** at stage 2 for trust-boundary changes: the `requesting-code-review`
  rubric is code-quality only, so the reviewer must also apply `security-and-owasp.instructions.md`.
- **Maker/checker principle required**: the stage-1/stage-2 reviewer must be a subagent distinct
  from the implementer (SDD's two-stage review; an orchestrator may require an *adversarial* verifier).
- **Resume from durable state, not memory**: an interrupted run reconciles from committed history +
  the run record (fingerprint-matched), not from the model's guess about the worktree; uncommitted
  changes at startup are untrusted and stashed, not built upon. The `RUN_ID` itself is durable too —
  minted once and persisted to a `runs/<id>.dispatch` breadcrumb, so resume recovers it automatically
  rather than relying on a human to remember it.
- **Evidence, not assertion**: completion requires command output evidence, not statements. Because
  the fingerprint is whole-tree, every required kind must pass against **one common final tree** —
  captures banked at earlier code states go stale. Step 2b converges all lanes onto that single
  fingerprint before the gate runs (a normal-flow discipline, not a recovery concern).
- **Self-heal cap**: SDD itself loops "until approved" with no bound; this skill's controller caps
  retries at `self_heal_attempts` (default 2) fix attempts per distinct failure, then stops and
  escalates `blocked` rather than thrashing. It is a controller-level prompt cap (no hook counts
  review rounds), distinct from any no-progress *stalled-pass* detector an orchestrator may add.
- **Draft-PR handoff** by default; this **overrides** `finishing-a-development-branch` (no local-merge menu). Merge policy is owned by repo process/CI.

## Gotchas

- **Resume keys on the *track slug*, not a remembered id.** Reuse the *exact* same slug between
  runs — saying "track `a`" then "track `auth`" reads as **two different tracks** and starts a fresh
  run. To force a clean restart, delete that track's `runs/*_<track>.*` files (or export a new
  `RUN_ID`); there is no `--resume` flag.
- **Never hand-set `RUN_ID`.** It is *minted once* by `track-preflight.sh` as
  `<UTC-timestamp>_<track>` and must stay **stable across restarts** so `track-reconcile.sh` reopens
  the same run record. Typing your own breaks resume.
- **A dirty worktree at startup is *untrusted*.** Uncommitted changes may predate tests/review, so
  reconcile **stashes** them (reversible) — never `git reset --hard` unfamiliar work and never build
  on top of it.
- **Doneness is mechanical, never a judgement call.** A task is "done" only when its evidence
  `fingerprint` matches the current tree. "All green" without pasted command output is **not** done.
- **Hooks are local and bypassable — they are defense-in-depth, not the merge gate.** Layer them
  (in-session hooks → git `pre-push` → **CI**); CI stays the only unbypassable authority.
- **Each `track-*.sh` no-ops until its env is set.** Dropping the bundle into `.github/hooks/` is
  safe, but the scripts **enforce nothing** until you export the matching vars (e.g.
  `TRACK_ALLOWED_PREFIXES`, `TRACK_EVIDENCE_RULES`).
- **Set `TRACK_BASE_REF` or the Stop evidence-gate leaks once work is committed.** The gate/reconcile
  derive "what changed" from the diff; with no base ref a **committed** change shows an empty
  diff-vs-HEAD, so the gate requires *nothing* and silently passes. Because the worker commits before
  the draft-PR handoff, treat `TRACK_BASE_REF` (e.g. `main`/`origin/main`) as **required**, not
  optional, for the gate to stay meaningful.
- **Gitignore `runs/` — this is correctness, not tidiness.** The evidence fingerprint is
  `git rev-parse HEAD` + `git diff HEAD`, which only sees *tracked* files. If `runs/*.json` is
  **tracked**, every evidence capture edits it, shifts the current fingerprint, and the gate reports
  the *just-captured* evidence as **STALE** — you can never pass your own gate. And it must be
  *ignored*, not merely untracked: reconcile's dirty check counts untracked-but-visible files
  (`git ls-files --others --exclude-standard`), so a non-ignored `runs/*.dispatch` breadcrumb makes
  the tree read **dirty** and gets stashed. Add `runs/` to `.gitignore` before the first run.
- **Don't freeze entrypoints on a bootstrap branch.** Leave `TRACK_FROZEN_PATHS` unset while the
  entrypoints don't exist yet; enable strict frozen paths only once parallel tracks begin.
- **The worker physically stops at `gh pr create --draft`.** Push/merge/force are denied by the
  guard — integration is owned by repo process/CI, not this skill.
- **Hook scripts are bash + `jq` only.** The bundle ships no PowerShell port; on non-bash surfaces
  run the scripts under a bash-compatible shell (they read stdin JSON and are otherwise
  surface-agnostic).
- **`[P]` is *not* the scaffold-mode trigger.** `[P]` marks file-disjointness, not
  non-behavioral-ness — it sits on security-critical tasks too. Scaffold mode keys on an explicit
  `scaffold_only` batch + the eligibility guard; a task with any test obligation or trust boundary
  **refuses the whole batch** to the normal SDD core. In-session fan-out is **generate-only** in the
  shared worktree (subagents return file bodies, the controller lands them serially) — true
  parallel-for-commits comes from worktree-per-track (`executing-parallel-tracks`), never from
  fanning multiple writers into one tree.

## Hooks (Optional, Composable) — Bundle Owned Here

The quality gates above are only as strong as the worker's compliance — unless you make the
*mechanical* ones (paths, forbidden commands, counters) **enforced**. This skill ships the canonical
hooks bundle ([`scripts/track-*.sh`](scripts/) + [`templates/track-hooks.json`](templates/track-hooks.json)),
which wires Copilot agent hooks to deny out-of-scope edits, lock workers out of push/merge, record
test evidence, and block completion when the evidence pack is incomplete. Each script is **opt-in and
no-ops until its env is set**, so dropping the bundle into `.github/hooks/` is safe before configuring
anything. Leave *judgement* gates (TDD ordering, the maker/checker split, review quality) as prompt
instructions — a hook cannot tell which subagent reasoned about something.

**Hooks are defense-in-depth, not the final gate.** Layer them: hooks (fast, in-session) → git
`pre-push` (local backstop) → **CI (the unbypassable merge gate)**.

See [`references/hooks.md`](references/hooks.md) for the full bundle: every script and its event, the
install/env reference, portability notes (no matchers, surface-specific event names), and exactly
what the `runs/<RUN_ID>.json` record does and does **not** capture.

## Scaffold Mode (Optional) — Batch In-Session Fan-Out

For a **narrow, explicitly-declared** class of work — *mechanical, non-behavioral bootstrap files
with no test obligation and no trust-boundary surface* (project skeletons, dependency manifests,
lint/compose/proxy/`Makefile` configs, test-harness scaffolding) — you may swap the SDD per-task loop
for a **batch** core that exploits `[P]` disjointness for parallel-generation latency:

1. **Guard** — assert **every** batched task is non-behavioral; **refuse the whole batch** (route to
   the normal SDD core) if any task has a test obligation, touches a trust boundary (input/auth/
   secrets/DB/network), or carries a security/correctness success-criterion.
2. **Fan out generation** (`dispatching-parallel-agents`) — N **read-only** subagents each *return a
   file body as text*; none writes to disk, runs tests, or commits (so no shared-index race).
3. **Apply** all bodies at once (controller = single writer) → one converged tree.
4. **One batch evidence** — build + lint + bring-up health check against the converged tree; **paste
   output**. This is **kept**, not skipped: it is the "does the scaffold actually build/come up" proof.
5. **One `requesting-code-review`** over the whole scaffold diff (quality-only is correct — the guard
   already established there is no trust-boundary surface), then the same **draft-PR finish**.

Preflight, isolation, run-log/`RUN_ID`, the hooks bundle, and the draft-PR boundary are **reused
unchanged** — scaffold mode swaps only the execution core, so it is a *mode*, not a forked skill.
TDD and the two-stage review are dropped **only because** the guard proved the batch is non-behavioral.

See [`references/scaffold-mode.md`](references/scaffold-mode.md) for the full flow, the eligibility
guard, and the drop-vs-keep table.

## Composition Contract

When composed by a parallel orchestrator, this skill's gates may be **tightened** by overlays such
as: distinct adversarial verifier subagent, draft-only/no-merge worker boundary, and stricter
run-id/trace requirements.

## References

- **Delegates the per-task implement → two-stage review loop to** `subagent-driven-development`,
  which **transitively** uses `test-driven-development` (implementation) and `requesting-code-review`
  (stage-2 rubric). Do **not** list those as separate steps — they are nested inside SDD.
- **Brackets that loop with** `using-git-worktrees` (isolation, before) and
  `verification-before-completion` (evidence gate, after).
- **Overrides** SDD's terminal `finishing-a-development-branch`: this skill stops at a **draft PR**
  (no local-merge menu); integration/merge is owned by repo process/CI.
- [`references/hooks.md`](references/hooks.md) — full hooks bundle: every script + event, install/env
  reference, portability notes, and what the run record does and doesn't capture.
- [`references/scaffold-mode.md`](references/scaffold-mode.md) — optional batch fan-out core for
  non-behavioral bootstrap: the eligibility guard, the generate→apply→batch-verify→review→PR flow,
  and the drop-vs-keep table.
- Related orchestrator: `../executing-parallel-tracks/SKILL.md` (dispatches one run of this skill
  per track and layers parallel-only overlays).
