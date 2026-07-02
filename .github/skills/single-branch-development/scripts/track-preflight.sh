#!/usr/bin/env bash
# track-preflight.sh — Start gate: mint (or recover) a stable RUN_ID, verify the run can
# actually proceed, and disambiguate START vs RESUME from a durable breadcrumb. Solves the
# "humans can't reproduce a RUN_ID from memory" footgun: the id is generated once and
# persisted to runs/<RUN_ID>.dispatch, so a later resume reads it back instead of guessing.
#
# Two phases (so the skill can show a summary, get confirmation, THEN persist):
#   inspect (default)  — detect resume-vs-fresh, check prerequisites, print a summary +
#                        emit JSON to stdout. READ-ONLY: writes nothing. Exit non-zero only
#                        on a HARD prerequisite failure (missing gh/git/toolchain) — a
#                        missing dep is not a preference, it blocks in every mode.
#   --commit           — persist runs/<RUN_ID>.dispatch (the breadcrumb) after the caller
#                        has confirmed. Idempotent: re-committing the same id is a no-op.
#
# Inputs (env or args):
#   TRACK_ID     short track slug (e.g. setup, us1). REQUIRED.
#   TASKS        human task range for the summary/breadcrumb (e.g. "T001-T009"). Optional.
#   RUN_ID       override the minted id (rare). If a breadcrumb for this TRACK_ID already
#                exists, its id WINS (resume) unless RUN_ID is set explicitly.
#   RUNS_DIR     default "runs".
#   TRACK_BASE_REF / default_branch  base for the new branch (summary only; default main).
#   PREFLIGHT_REQUIRE_TOOLCHAIN  comma list of extra bins to require (e.g. "go,uv,node").
#   PREFLIGHT_REQUIRE_GH         "1" (default) to require an authenticated gh; "0" to skip
#                                (e.g. a setup run that won't open a PR until later).
#
# Resume detection: the NEWEST runs/*.dispatch whose track==TRACK_ID. Its run_id is the
# resume key; the caller then hands that RUN_ID to track-reconcile.sh.
#
# Requires: jq, git. gh only when PREFLIGHT_REQUIRE_GH=1. Keep runtime < 5s.
set -eufo pipefail

mode="inspect"
for a in "$@"; do
  case "$a" in
    --commit) mode="commit" ;;
    --inspect) mode="inspect" ;;
  esac
done

RUNS_DIR="${RUNS_DIR:-runs}"
track="${TRACK_ID:-}"
tasks="${TASKS:-}"
base="${TRACK_BASE_REF:-${default_branch:-main}}"
require_gh="${PREFLIGHT_REQUIRE_GH:-1}"

err() { printf '%s\n' "preflight: $1" >&2; }
die() { err "$1"; exit 1; }

[ -n "$track" ] || die "TRACK_ID is required (the track slug, e.g. setup / us1)."
command -v jq  >/dev/null 2>&1 || die "jq not found."
command -v git >/dev/null 2>&1 || die "git not found."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree."

mkdir -p "$RUNS_DIR" 2>/dev/null || true
[ -w "$RUNS_DIR" ] || die "$RUNS_DIR is not writable."

# --- resume detection: newest breadcrumb for this track ----------------------------
# NOTE: `set -f` (noglob) is active, so shell globbing of *.dispatch is disabled — use
# `find` (which does its own matching) rather than an `ls runs/*.dispatch` shell glob.
existing_id=""
existing_file=""
# Build a mtime-sorted (newest first) list, then scan with a here-string so the matched
# filename survives in this shell (a pipe-to-while would set it inside a lost subshell).
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
  t="$(jq -r '.track // empty' "$f" 2>/dev/null || true)"
  if [ "$t" = "$track" ]; then
    existing_file="$f"; existing_id="$(jq -r '.run_id // empty' "$f" 2>/dev/null)"; break
  fi
done <<<"$sorted"

# --- pick RUN_ID: explicit override > existing breadcrumb (resume) > mint fresh -----
resume=false
if [ -n "${RUN_ID:-}" ]; then
  run_id="$RUN_ID"
  [ -n "$existing_id" ] && [ "$existing_id" = "$run_id" ] && resume=true
elif [ -n "$existing_id" ]; then
  run_id="$existing_id"; resume=true
else
  run_id="$(date -u +%Y-%m-%dT%H-%M)_${track}"
fi
rec_dispatch="$RUNS_DIR/$run_id.dispatch"

# --- prerequisite checks (hard) ----------------------------------------------------
missing=""
if [ "$require_gh" = "1" ]; then
  if command -v gh >/dev/null 2>&1; then
    gh auth status >/dev/null 2>&1 || missing="$missing gh(not-authed)"
  else
    missing="$missing gh(absent)"
  fi
fi
if [ -n "${PREFLIGHT_REQUIRE_TOOLCHAIN:-}" ]; then
  saved_ifs="$IFS"; IFS=,
  for bin in $PREFLIGHT_REQUIRE_TOOLCHAIN; do
    [ -n "$bin" ] || continue
    command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin(absent)"
  done
  IFS="$saved_ifs"
fi
missing="$(printf '%s' "$missing" | sed 's/^ *//')"

branch="$track"
prereq_ok=true; [ -n "$missing" ] && prereq_ok=false

# --- commit phase: persist the breadcrumb, then exit -------------------------------
if [ "$mode" = "commit" ]; then
  [ "$prereq_ok" = true ] || die "refusing to commit breadcrumb — unmet prerequisites:$missing"
  if [ -f "$rec_dispatch" ]; then
    printf '%s\n' "preflight: breadcrumb already present ($rec_dispatch) — no-op." >&2
  else
    jq -nc \
      --arg run_id "$run_id" --arg track "$track" --arg tasks "$tasks" \
      --arg branch "$branch" --arg base "$base" \
      --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{run_id:$run_id, track:$track, tasks:$tasks, branch:$branch, base_ref:$base, created_utc:$created}' \
      > "$rec_dispatch"
  fi
  printf '%s\n' "$run_id"
  exit 0
fi

# --- inspect phase: human summary (stderr) + machine JSON (stdout) ------------------
{
  echo "PREFLIGHT — single-branch-development"
  echo "  Mode:         $([ "$resume" = true ] && echo 'RESUME (breadcrumb found)' || echo 'START (fresh)')"
  echo "  Track:        $track"
  echo "  Tasks:        ${tasks:-<unspecified>}"
  echo "  RUN_ID:       $run_id $([ "$resume" = true ] && echo '(recovered)' || echo '(generated)')"
  [ -n "$existing_file" ] && echo "  Breadcrumb:   $existing_file"
  echo "  Branch:       $branch"
  echo "  Base ref:     $base"
  if [ "$prereq_ok" = true ]; then
    echo "  Prereqs:      OK (git ✓ · runs/ ✓ writable$([ "$require_gh" = 1 ] && echo ' · gh ✓ authed')${PREFLIGHT_REQUIRE_TOOLCHAIN:+ · $PREFLIGHT_REQUIRE_TOOLCHAIN ✓})"
    echo "  → Proceed?    confirm to dispatch (then re-run with --commit to persist the breadcrumb)"
  else
    echo "  Prereqs:      BLOCKED — missing:$missing"
    echo "  → Fix the missing prerequisite before dispatching."
  fi
} >&2

jq -nc \
  --arg run_id "$run_id" --arg track "$track" --arg tasks "$tasks" \
  --arg branch "$branch" --arg base "$base" \
  --argjson resume "$resume" --argjson prereq_ok "$prereq_ok" \
  --arg missing "$missing" --arg breadcrumb "$existing_file" \
  '{run_id:$run_id, track:$track, tasks:$tasks, branch:$branch, base_ref:$base,
    mode:(if $resume then "resume" else "start" end),
    prereq_ok:$prereq_ok,
    missing:($missing | if . == "" then [] else split(" ") end),
    breadcrumb:($breadcrumb | if . == "" then null else . end)}'

[ "$prereq_ok" = true ] || exit 3
exit 0
