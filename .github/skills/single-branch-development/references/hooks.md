# Hooks Bundle (Optional, Composable)

This skill **ships the canonical hooks bundle** ([`../scripts/track-*.sh`](../scripts/) +
[`../templates/track-hooks.json`](../templates/track-hooks.json)). The quality gates in `SKILL.md`
are only as strong as the worker's compliance — unless you make them **mechanical**. Hooks turn the
*mechanical* gates (paths, forbidden commands, counters) into enforced ones; *judgement* gates (TDD
ordering, the maker/checker split, review quality) stay as prompt instructions because a hook cannot
tell which subagent reasoned about something.

Orchestrators that compose this skill reuse the same files and only layer extra env on top.

## How Copilot Hooks Work

Copilot's native [agent hooks](https://docs.github.com/en/copilot/concepts/agents/hooks) run shell
commands at lifecycle points (`PreToolUse`, `PostToolUse`, `SubagentStart`, `SubagentStop`, `Stop`,
…) and can **block a tool call before it happens**. Config lives in `.github/hooks/*.json`
(repo-scoped, so it travels with each worktree) and is read by VS Code Agent Mode, the Copilot CLI,
and the cloud agent. A `PreToolUse` hook receives the tool call as JSON on stdin and denies it via
exit code `2` (stderr → model) or `hookSpecificOutput.permissionDecision: "deny"`.

## Portability (No Matchers; Event Names Differ)

- **No `matcher` field.** Unlike Claude Code, Copilot hooks cannot scope to specific tools in
  config. A `PreToolUse` hook fires on **every** tool call, so the script must branch on `tool_name`
  from stdin and early-exit (allow) for tools it doesn't care about — which `track-guard.sh` already
  does.
- **Event names differ by surface.** The bundled `track-hooks.json` uses the VS Code keys
  (`preToolUse`, `postToolUse`, `subagentStart`, `subagentStop`, `stop`); the Copilot CLI /
  cloud-agent docs name the same events `agentStop` / `subagentStop` / `userPromptSubmitted` /
  `sessionEnd`. The *scripts* are surface-agnostic (they read stdin JSON); only the registration keys
  change if you run them under the CLI instead of VS Code.
- **Bash + `jq` only.** The bundle ships no PowerShell port; on non-bash surfaces run the scripts
  under a bash-compatible shell.

## Bundled Scripts

| Pipeline gate | Bundled script (event) | What it does |
|---|---|---|
| Start gate / mint-or-recover RUN_ID | `track-preflight.sh` (manual / skill Step 0a) | **Start gate.** `inspect` mints a stable `RUN_ID` = `<UTC>_<track>` on a fresh start, or **recovers** it from an existing `runs/<id>.dispatch` breadcrumb (resume), then checks prerequisites (git tree, `runs/` writable, opt. `gh` auth + `PREFLIGHT_REQUIRE_TOOLCHAIN` bins). Prints a confirm summary + JSON; **hard-fails non-zero** on any unmet prereq (both interactive and `auto_confirm`). `--commit` persists the breadcrumb (track, tasks, branch, base ref) so resume is self-recovering. Run by the skill, not a hook, since it precedes RUN_ID. |
| Resume / reconcile after interruption | `track-reconcile.sh` (`SessionStart`/`agentStart`) | **Read-only** preflight: from committed history + `runs/<RUN_ID>.json` only, emit `{head, dirty_worktree, evidence:{fresh,stale,missing,failed}, resumable}` at the current fingerprint — so a crashed/credit-out run resumes at the first not-done task and stashes untrusted uncommitted work, instead of the model guessing where it left off. Self-recovers `RUN_ID` from the `runs/<id>.dispatch` breadcrumb when none is exported. No-op unless a `RUN_ID` is set or recoverable. Mirrors `track-evidence-gate.sh`'s fingerprint logic exactly. |
| Scope / never edit frozen entrypoints | `track-guard.sh` (`PreToolUse`) | **Deny** an edit whose target path is outside `TRACK_ALLOWED_PREFIXES` or hits a `TRACK_FROZEN_PATHS` entrypoint (deny-by-default, per worktree). |
| Never hand-edit generated or applied artifacts | `track-guard.sh` (`PreToolUse`) | **Deny** edits to any file carrying a `GENERATED — DO NOT EDIT` banner (re-run the generator), and to already-committed files under `TRACK_IMMUTABLE_PREFIXES` (e.g. applied migrations — add a NEW file instead). A brand-new file under the prefix is allowed. |
| No auto-merge from a worker | `track-guard.sh` (`PreToolUse`) | **Deny** `git push`, `gh pr merge`, `--force`, `--no-verify`, `git reset --hard` on terminal calls. Workers physically stop at `gh pr create --draft`. |
| No irreversible data/infra ops *(opt-in)* | `track-guard.sh` (`PreToolUse`) | When `TRACK_GUARD_DESTRUCTIVE` is set, **deny** `DROP`/`TRUNCATE`, unbounded `DELETE FROM` (no `WHERE`), Redis `FLUSHALL`/`FLUSHDB`, NATS stream/consumer teardown, and `rm -rf` on absolute/home paths. Stack-specific — tune the patterns. |
| Evidence gate (recorded test output) | `track-evidence.sh` (`PostToolUse`) | Append `{kind, cmd, response, fingerprint}` for test commands into the run record — captured by the tool, not claimed by the model. `fingerprint` (HEAD + tracked diff) ties each entry to the exact code it tested. **`tool_response` is textual, not a numeric exit code** (CI stays the pass/fail authority). |
| Evidence pack complete + fresh *(opt-in)* | `track-evidence-gate.sh` (`Stop`) | The closing “missing rows = not done” assertion. The required-kind set is **diff-conditional**: `TRACK_EVIDENCE_RULES` (`glob:kind` pairs) selects kinds by the paths the branch touched — so a frontend-only diff needs `ts`, a migration diff needs `pg-explain` — unioned with the optional always-on floor `TRACK_REQUIRED_EVIDENCE`. **`decision:block`** unless every selected kind has an entry whose `fingerprint` matches the **current** tree and whose response shows no failure marker — reporting exactly which are MISSING / STALE / FAILING. Selection is mechanical glob-matching (no model call); no-ops when both vars are unset or the diff selects nothing. Honors `stop_hook_active`; failure markers extend via `TRACK_FAIL_PATTERN`. Mechanizes verification-before-completion; CI stays authoritative. |
| Tool-call ceiling | `track-meter.sh` (`PostToolUse`) | Count tool calls; emit `continue:false` + set `status:no-progress` when `TRACK_MAX_TOOL_CALLS` trips. **Hook I/O carries no token/cost data**, so token/$ ceilings stay orchestrator-side. |
| Activation trace | `track-trace.sh` (`SubagentStart`/`SubagentStop`) | Append a `trace` entry per subagent spawn/stop. The `Run-Id:` *commit trailer* is NOT set here — add it in the worker's commit command or a git `prepare-commit-msg` hook. |
| Pre-handoff secret/leftover scan *(opt-in)* | `track-sentinel.sh` (`Stop`) | When `TRACK_SENTINEL` is set, scan the **staged diff** and `decision:block` if it finds a likely secret or debug leftover (`console.log`, `debugger`, `TODO(claude)`, `FIXME`). Honors `stop_hook_active` so it can't loop; patterns override via `TRACK_SECRET_PATTERN`/`TRACK_LEFTOVER_PATTERN`. Defense-in-depth — CI/secret-scanning stays authoritative. |
| Completion notification | `track-notify.sh` (`Stop`) | `curl` the run's terminal state to `TRACK_NOTIFY_WEBHOOK`. Best-effort; never blocks or fails the session. |

## Install

Copy every [`../scripts/track-*.sh`](../scripts/) into the repo's `.github/hooks/` directory and
place [`../templates/track-hooks.json`](../templates/track-hooks.json) there too. Each script is
**opt-in and no-ops unless its env is set**, so dropping them in is safe before configuring anything:

```bash
export TRACK_ALLOWED_PREFIXES="src/feature:test/feature"   # guard: this branch's writable scope
export RUN_ID="2026-06-27T14-03_feat"                       # <UTC-timestamp>_<track> — usually MINTED by track-preflight.sh (Step 0a), not hand-set; STABLE across restarts so reconcile resumes the same record
export TRACK_FROZEN_PATHS="cmd/main.go:internal/app/app.go" # guard: frozen entrypoints (see caveat)
export RUNS_DIR="runs"                                       # RUN_ID keys the record + runs/<id>.dispatch breadcrumb. GITIGNORE THIS DIR: it's local run state, and if tracked, evidence writes shift the fingerprint (gate sees its own capture as STALE) and reconcile reads the tree as dirty (see Gotchas).
# OPTIONAL — each stays off until set
export TRACK_ID="setup"                                     # preflight: track slug for breadcrumb resume-matching
export PREFLIGHT_REQUIRE_GH=1                               # preflight: require authenticated gh (0 to waive for early setup runs)
export PREFLIGHT_REQUIRE_TOOLCHAIN="go,uv"                  # preflight: extra bins that must be on PATH
export TRACK_IMMUTABLE_PREFIXES="migrations/"               # guard: committed files here are append-only
export TRACK_GUARD_DESTRUCTIVE=1                            # guard: deny DROP/TRUNCATE/FLUSHALL/etc.
export TRACK_SENTINEL=1                                     # Stop: scan staged diff for secrets/leftovers
export TRACK_TEST_CMD_PATTERN="go test|uv run pytest|npm (run )?test"  # evidence
export TRACK_EVIDENCE_KINDS="go-test:go test -race;py:uv run pytest;ts:tsc --noEmit"  # tag evidence by pack row
export TRACK_EVIDENCE_RULES="*.go:go-test;*.py:py;*.tsx:ts;*.ts:ts;migrations/*:pg-explain"  # Stop gate: diff path → required kind
export TRACK_REQUIRED_EVIDENCE=""             # Stop gate: kinds required on EVERY diff (floor); empty = rules-only
export TRACK_BASE_REF="main"                  # Stop gate / reconcile: diff base. STRONGLY RECOMMENDED — without it, once work is COMMITTED the diff-vs-HEAD is empty so the gate requires nothing and silently passes (see Gotchas). Falls back to branch upstream, then HEAD-only.
export TRACK_MAX_TOOL_CALLS=200                                       # tool-call ceiling
export TRACK_NOTIFY_WEBHOOK="https://hooks.slack.com/services/..."     # notify
```

**Hooks are defense-in-depth, not the final gate.** They are local and bypassable. Layer them:
hooks (fast, in-session) → git `pre-push` (local backstop) → **CI (the unbypassable merge gate)**.

For foundation/bootstrap runs, avoid freezing paths too early. If entrypoints do not exist yet,
leave `TRACK_FROZEN_PATHS` unset for the bootstrap branch, then enable strict frozen entrypoints for
subsequent parallel tracks.

## What the Run Record Captures (and What It Deliberately Doesn't)

The run record `runs/<RUN_ID>.json` is written **per hook event, not per loop iteration**, and only
holds what hooks can actually observe. It is **opt-in**: every field below stays empty unless the
hook *and* its env are set — launch without them and the run still works but records nothing.

| Recorded | Field | Written on | Source |
|---|---|---|---|
| Tool-call count | `tool_calls` (running integer) | **every** `PostToolUse` | `track-meter.sh` — `+1` per call; halts at `TRACK_MAX_TOOL_CALLS` |
| Subagent spawn/stop timeline | `trace[]` (`{t, kind, event, agent_id, agent_type}`) | `SubagentStart` / `SubagentStop` | `track-trace.sh` |
| Test evidence | `evidence[]` (`{t, kind, cmd, response, fingerprint}`) | `PostToolUse` matching a **test** command only | `track-evidence.sh` |
| Terminal state | `status` (`no-progress` / `blocked` / …) | on a hard stop | `track-meter.sh` / `track-evidence-gate.sh` |

**Deliberately NOT recorded** (don't expect these in the file):

- **No loop / review-iteration count.** The TDD + 2-stage-review loop and the `self_heal_attempts`
  cap live inside SDD's in-context reasoning; hooks never see review rounds. `tool_calls` is the only
  (approximate) "turns" proxy.
- **No token or cost data.** Hook I/O carries none, so only a **tool-call** ceiling is enforceable
  here; token/$ ceilings stay orchestrator-side.
- **No per-tool argument log.** `tool_calls` is a bare counter; non-test tool calls (reads, `ls`,
  edits) tick it but are not itemized. Only **test** commands land in `evidence[]`.
- **`response` is textual, not an exit code.** `PostToolUse` exposes a (possibly truncated) text
  result, so CI — not the recorded string — remains the authoritative pass/fail.
