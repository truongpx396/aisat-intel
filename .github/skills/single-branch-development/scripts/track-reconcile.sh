#!/usr/bin/env bash
# track-reconcile.sh — Resume/Reconcile preflight: deterministically answer "where did
# an interrupted run leave off?" from PERSISTED STATE ONLY (committed history + the run
# record), never from the model's reading of the worktree. Mirrors the workflow-engine
# pattern (Temporal/Argo replay): rebuild position from a durable log, then move forward.
#
# This is advisory and READ-ONLY by default. It prints a JSON report; it does NOT mutate
# the repo. The skill's Step 0 consumes the report and decides the (reversible) cleanup
# (git stash of untrusted changes) and which task to resume — the model only ever picks
# the NEXT not-done task, never judges a task "done". Doneness stays mechanical here.
#
# What it computes (all deterministic — no model call):
#   1. dirty            — is the working tree dirty? Uncommitted edits at startup are
#                         UNTRUSTED (tests/review may not have run) and must not be built
#                         upon. Reported so Step 0 can `git stash` them (reversible),
#                         not `git reset --hard` (destructive).
#   2. head / branch    — the last durable commit to resume from.
#   3. evidence freshness per required kind at the CURRENT fingerprint, reusing
#      track-evidence-gate.sh's exact fingerprint + rule-selection logic:
#         fresh  = entry exists, fingerprint==current, no failure marker  -> proven done
#         stale  = entry exists but fingerprint!=current                  -> re-verify
#         missing= no entry for a diff-required kind                      -> not done
#
# Opt-in / no-op unless RUN_ID is set (matches the rest of the track-*.sh bundle). Honors
# the same env: RUN_ID, RUNS_DIR, TRACK_REQUIRED_EVIDENCE, TRACK_EVIDENCE_RULES,
# TRACK_BASE_REF, TRACK_FAIL_PATTERN. Surface-agnostic: reads stdin JSON (may be empty),
# branches on nothing tool-specific. Wire it at SessionStart / agentStart, or run it by
# hand at the top of a resumed session.
#
# Requires: jq, git. Keep runtime < 5s.
set -eufo pipefail

input="$(cat 2>/dev/null || true)"

RUNS_DIR="${RUNS_DIR:-runs}"

# --- self-recovering resume: if no RUN_ID was provided, adopt it from the breadcrumb
# that track-preflight.sh persisted (runs/<id>.dispatch). This is the whole point of the
# breadcrumb — a resumed session need not have a human remember/retype the RUN_ID. Pick
# the newest breadcrumb for TRACK_ID if set, else the newest breadcrumb overall.
# NOTE: `set -f` (noglob) is active — use `find`, not a shell *.dispatch glob.
if [ -z "${RUN_ID:-}" ]; then
  want_track="${TRACK_ID:-}"
  sorted=""
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
    sorted="$sorted$mt	$f
"
  done <<<"$(find "$RUNS_DIR" -maxdepth 1 -type f -name '*.dispatch' 2>/dev/null || true)"
  sorted="$(printf '%s' "$sorted" | sort -rn)"
  while IFS="$(printf '\t')" read -r _ f; do
    [ -n "${f:-}" ] || continue
    if [ -z "$want_track" ] || [ "$(jq -r '.track // empty' "$f" 2>/dev/null || true)" = "$want_track" ]; then
      RUN_ID="$(jq -r '.run_id // empty' "$f" 2>/dev/null)"; break
    fi
  done <<<"$sorted"
fi

# Opt-in / no-op: nothing to reconcile without a RUN_ID (none given, none recoverable).
[ -n "${RUN_ID:-}" ] || exit 0

rec="$RUNS_DIR/$RUN_ID.json"

# --- durable position --------------------------------------------------------------
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
head="$(git rev-parse HEAD 2>/dev/null || echo no-head)"
# Dirty = staged or unstaged tracked changes, or untracked non-ignored files.
dirty=false
if ! git diff --quiet HEAD 2>/dev/null \
   || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
  dirty=true
fi

# --- current fingerprint — MUST match track-evidence{,-gate}.sh exactly -------------
hash_cmd() { if command -v shasum >/dev/null 2>&1; then shasum; else sha1sum; fi; }
current_fp="$({ git rev-parse HEAD 2>/dev/null || echo no-head; git diff HEAD 2>/dev/null || true; } | hash_cmd | cut -d' ' -f1)"

# --- required-kind set: static floor UNION diff-derived rules (gate parity) ---------
base="${TRACK_BASE_REF:-}"
[ -n "$base" ] || base="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
committed=""
if [ -n "$base" ] && git rev-parse --verify -q "$base" >/dev/null 2>&1; then
  committed="$(git diff --name-only "$base"...HEAD 2>/dev/null || true)"
fi
worktree="$(git diff --name-only HEAD 2>/dev/null || true)"
untracked="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
touched="$(printf '%s\n%s\n%s\n' "$committed" "$worktree" "$untracked" | sed '/^$/d' | sort -u)"

required=""
if [ -n "${TRACK_REQUIRED_EVIDENCE:-}" ]; then
  saved_ifs="$IFS"; IFS=,
  for k in $TRACK_REQUIRED_EVIDENCE; do [ -n "$k" ] && required="$required $k"; done
  IFS="$saved_ifs"
fi
if [ -n "${TRACK_EVIDENCE_RULES:-}" ] && [ -n "$touched" ]; then
  saved_ifs="$IFS"; IFS=';'
  for rule in $TRACK_EVIDENCE_RULES; do
    glob="${rule%%:*}"; kind="${rule#*:}"
    [ -n "$glob" ] && [ -n "$kind" ] && [ "$glob" != "$rule" ] || continue
    glob="${glob#\*\*/}"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # shellcheck disable=SC2254
      case "$p" in
        $glob) required="$required $kind"; break ;;
      esac
    done <<<"$touched"
    IFS=';'
  done
  IFS="$saved_ifs"
fi
required="$(printf '%s\n' $required | sed '/^$/d' | sort -u | tr '\n' ' ')"

fail_re="${TRACK_FAIL_PATTERN:-}"
[ -n "$fail_re" ] || fail_re='\bFAIL\b|FAILED|panic:|Traceback|error TS[0-9]|\bERROR\b|✖|exit code [1-9]|[1-9][0-9]* (failed|error)'

# --- classify each required kind against the run record at current_fp ---------------
fresh=""; stale=""; missing=""; failed=""
if [ -n "${required// /}" ] && [ -f "$rec" ]; then
  for kind in $required; do
    [ -n "$kind" ] || continue
    entry="$(jq -c --arg k "$kind" '[.evidence[]? | select(.kind == $k)] | last // empty' "$rec" 2>/dev/null || true)"
    if [ -z "$entry" ] || [ "$entry" = "null" ]; then missing="$missing $kind"; continue; fi
    fp="$(jq -r '.fingerprint // empty' <<<"$entry")"
    resp="$(jq -r '.response // empty' <<<"$entry")"
    if [ "$fp" != "$current_fp" ]; then stale="$stale $kind"; continue; fi
    if printf '%s' "$resp" | grep -Eq "$fail_re"; then failed="$failed $kind"; continue; fi
    fresh="$fresh $kind"
  done
elif [ -n "${required// /}" ]; then
  missing="$required"   # required kinds but no run record at all
fi

trim() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }
# resumable = clean tree AND nothing missing/stale/failed for the current diff.
resumable=false
if [ "$dirty" = false ] && [ -z "$(trim "$missing$stale$failed")" ]; then resumable=true; fi

jq -nc \
  --arg run_id "$RUN_ID" \
  --arg branch "$branch" \
  --arg head "$head" \
  --arg fp "$current_fp" \
  --argjson dirty "$dirty" \
  --argjson resumable "$resumable" \
  --arg fresh "$(trim "$fresh")" \
  --arg stale "$(trim "$stale")" \
  --arg missing "$(trim "$missing")" \
  --arg failed "$(trim "$failed")" \
  --arg rec "$rec" \
  '{
     run_id: $run_id, branch: $branch, head: $head, fingerprint: $fp,
     run_record: $rec, dirty_worktree: $dirty, resumable: $resumable,
     evidence: {
       fresh:   ($fresh   | if . == "" then [] else split(" ") end),
       stale:   ($stale   | if . == "" then [] else split(" ") end),
       missing: ($missing | if . == "" then [] else split(" ") end),
       failed:  ($failed  | if . == "" then [] else split(" ") end)
     },
     note: (if $dirty then "Uncommitted changes are UNTRUSTED — git stash (reversible) before resuming; do not build on them." else "Clean tree — resume from HEAD." end)
   }'

exit 0
