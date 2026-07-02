#!/usr/bin/env bash
# track-evidence.sh — PostToolUse: record test-command results into the run record.
#
# Makes the evidence gate tool-recorded instead of model-claimed. When a terminal
# command matches the manifest's test pattern, append { command, response } to
# runs/<RUN_ID>.json so the evidence is captured by the tool, not pasted by the model.
#
# This is the CAPTURE half of the evidence gate. The closing assertion — a fresh,
# passing entry must exist for every required pack row before done is claimed — lives
# in track-evidence-gate.sh (Stop). Capture must run on every PostToolUse so the
# record cannot be back-filled or cherry-picked at the claim moment.
#
# ACCURACY: PostToolUse exposes `tool_response` (a TEXTUAL result, possibly
# truncated) — NOT a numeric exit code. This records what the tool reported; CI
# remains the authoritative pass/fail gate.
#
# Opt-in via env (no-op unless a matcher is set):
#   RUN_ID                  stable run-id for this worker (also the record filename)
#   TRACK_TEST_CMD_PATTERN  ERE matched against the command, e.g.
#                           "go test|uv run pytest|npm (run )?test|pnpm test"
#   TRACK_EVIDENCE_KINDS    (optional) ';'-separated label:ERE pairs that both match
#                           AND tag a command with a pack kind, e.g.
#                           "go-test:go test -race;py:uv run pytest;ts:tsc --noEmit".
#                           A command matching any pair is recorded with that label
#                           so track-evidence-gate.sh can require a fresh, passing
#                           entry per kind. Patterns are repo-supplied, never baked in.
#   RUNS_DIR                where run records live (default: runs)
#
# Each entry also stores a `fingerprint` (HEAD + tracked diff hash) so the gate can
# tell evidence for the CURRENT tree from a stale green run captured edits ago.
set -eufo pipefail

[ -n "${RUN_ID:-}" ] || exit 0
[ -n "${TRACK_TEST_CMD_PATTERN:-}${TRACK_EVIDENCE_KINDS:-}" ] || exit 0

input="$(cat)"
tool="$(jq -r '.tool_name // empty' <<<"$input")"
case "$tool" in run_in_terminal | bash | shell) ;; *) exit 0 ;; esac

cmd="$(jq -r '.tool_input.command // .tool_input.bash // empty' <<<"$input")"
[ -n "$cmd" ] || exit 0

# Derive the pack kind from repo-supplied label:pattern pairs (first match wins).
kind=""
if [ -n "${TRACK_EVIDENCE_KINDS:-}" ]; then
  saved_ifs="$IFS"; IFS=';'
  for pair in $TRACK_EVIDENCE_KINDS; do
    label="${pair%%:*}"; pat="${pair#*:}"
    [ -n "$label" ] && [ -n "$pat" ] && [ "$label" != "$pair" ] || continue
    if printf '%s' "$cmd" | grep -Eq "$pat"; then kind="$label"; break; fi
  done
  IFS="$saved_ifs"
fi

# Record if it matches the test pattern OR any declared kind; tag a default kind.
matched=0
if [ -n "${TRACK_TEST_CMD_PATTERN:-}" ] && printf '%s' "$cmd" | grep -Eq "$TRACK_TEST_CMD_PATTERN"; then
  matched=1; [ -n "$kind" ] || kind="test"
fi
[ -n "$kind" ] && matched=1
[ "$matched" -eq 1 ] || exit 0

resp="$(jq -r '.tool_response // empty' <<<"$input")"

# Fingerprint of the code this evidence is for: HEAD + all tracked (staged+unstaged)
# changes. Untracked new files are NOT captured — stage them to include. Must match
# the identical computation in track-evidence-gate.sh.
hash_cmd() { if command -v shasum >/dev/null 2>&1; then shasum; else sha1sum; fi; }
fingerprint="$({ git rev-parse HEAD 2>/dev/null || echo no-head; git diff HEAD 2>/dev/null || true; } | hash_cmd | cut -d' ' -f1)"

RUNS_DIR="${RUNS_DIR:-runs}"
rec="$RUNS_DIR/$RUN_ID.json"
mkdir -p "$RUNS_DIR"
[ -f "$rec" ] || printf '{"run_id":"%s","trace":[],"evidence":[]}\n' "$RUN_ID" >"$rec"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp)"
jq --arg t "$ts" --arg k "$kind" --arg c "$cmd" --arg r "$resp" --arg f "$fingerprint" \
  '.evidence = ((.evidence // []) + [{t:$t, kind:$k, cmd:$c, response:$r, fingerprint:$f}])' "$rec" >"$tmp" && mv "$tmp" "$rec"
exit 0
