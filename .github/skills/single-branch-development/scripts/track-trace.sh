#!/usr/bin/env bash
# track-trace.sh — SubagentStart / SubagentStop: append to the run's activation trace.
#
# Builds the "skill → subagent → skill …" activation trace mechanically, so the run
# record shows which step a worker was in without reading the full transcript.
#
# NOTE: this records SUBAGENT spawn/stop events (the data hooks actually expose).
# The `Run-Id:` COMMIT trailer is NOT added here — a Copilot hook can't cleanly
# rewrite an already-made commit. Add that trailer in the worker's commit command
# (prompt-enforced) or via a git `prepare-commit-msg` hook.
#
# Opt-in via env (no-op unless RUN_ID is set):
#   RUN_ID    stable run-id for this worker
#   RUNS_DIR  where run records live (default: runs)
set -eufo pipefail

[ -n "${RUN_ID:-}" ] || exit 0

input="$(cat)"
ev="$(jq -r '.hook_event_name // empty' <<<"$input")"
aid="$(jq -r '.agent_id // empty' <<<"$input")"
atype="$(jq -r '.agent_type // empty' <<<"$input")"

RUNS_DIR="${RUNS_DIR:-runs}"
rec="$RUNS_DIR/$RUN_ID.json"
mkdir -p "$RUNS_DIR"
[ -f "$rec" ] || printf '{"run_id":"%s","trace":[]}\n' "$RUN_ID" >"$rec"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp)"
jq --arg t "$ts" --arg e "$ev" --arg id "$aid" --arg ty "$atype" \
  '.trace = ((.trace // []) + [{t:$t, kind:"subagent", event:$e, agent_id:$id, agent_type:$ty}])' \
  "$rec" >"$tmp" && mv "$tmp" "$rec"
exit 0
