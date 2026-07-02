#!/usr/bin/env bash
# track-meter.sh — PostToolUse: enforce a per-worker tool-call ceiling (hard stop).
#
# Counts tool calls in runs/<RUN_ID>.json and halts the session via `continue:false`
# when the ceiling trips — the mechanical backstop for the skill's "max iterations"
# hard stop.
#
# LIMITATION: hook I/O carries NO token/cost data, so this enforces a TOOL-CALL
# ceiling only. Token/$ ceilings (per-worker and the global fleet ceiling) must stay
# orchestrator-side. A tool-call count approximates "turns"; it is not identical.
#
# Opt-in via env (no-op unless the ceiling is set):
#   TRACK_MAX_TOOL_CALLS  integer ceiling; halt the worker once exceeded
#   RUN_ID                stable run-id for this worker
#   RUNS_DIR              where run records live (default: runs)
set -eufo pipefail

[ -n "${TRACK_MAX_TOOL_CALLS:-}" ] || exit 0
[ -n "${RUN_ID:-}" ] || exit 0

RUNS_DIR="${RUNS_DIR:-runs}"
rec="$RUNS_DIR/$RUN_ID.json"
mkdir -p "$RUNS_DIR"
[ -f "$rec" ] || printf '{"run_id":"%s","trace":[],"tool_calls":0}\n' "$RUN_ID" >"$rec"

count="$(jq -r '(.tool_calls // 0) + 1' "$rec")"
tmp="$(mktemp)"
jq --argjson n "$count" '.tool_calls = $n' "$rec" >"$tmp" && mv "$tmp" "$rec"

if [ "$count" -gt "$TRACK_MAX_TOOL_CALLS" ]; then
  # Also record the terminal state for the orchestrator's summary.
  tmp2="$(mktemp)"
  jq '.status = "no-progress"' "$rec" >"$tmp2" && mv "$tmp2" "$rec"
  jq -nc --arg r "tool-call ceiling ($TRACK_MAX_TOOL_CALLS) exceeded for run $RUN_ID; halting per hard-stop policy (status: no-progress)" \
    '{continue:false, stopReason:$r}'
fi
exit 0
