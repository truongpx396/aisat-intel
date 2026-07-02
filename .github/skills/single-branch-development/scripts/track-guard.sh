#!/usr/bin/env bash
# track-guard.sh — PreToolUse guard for the executing-parallel-tracks skill.
#
# Makes two of the skill's gates MECHANICAL instead of prompt-trusted:
#   1. Deny-by-default file ownership (per worktree) + frozen entrypoints.
#   2. Worker push/merge lockout — workers stop at `gh pr create --draft`.
#
# Wiring: copy this file + the bundled track-hooks.json into the repo's
# .github/hooks/ directory (the JSON points VS Code / Copilot CLI / cloud agent
# at this script).
# Requires: jq. Keep runtime < 5s — hooks block the agent synchronously.
#
# Per-worktree scope (export BEFORE launching each worker):
#   TRACK_ALLOWED_PREFIXES  colon-separated workspace-relative path prefixes this
#                           track may edit, e.g.
#                           "internal/ingest:migrations/0007_:test/ingest"
#   TRACK_FROZEN_PATHS      colon-separated exact files no track may edit, e.g.
#                           "cmd/main.go:internal/app/app.go"
#   TRACK_IMMUTABLE_PREFIXES  (optional) colon-separated prefixes whose
#                           already-committed files are append-only, e.g.
#                           "migrations/:backend-go/migrations/". A NEW file under
#                           the prefix is fine; editing one with git history is denied.
#
# Always-on (no env needed): any file whose first 3 lines carry a
# "GENERATED — DO NOT EDIT" banner is denied — re-run its generator instead.
#
# Opt-in destructive-infra guard (off unless set):
#   TRACK_GUARD_DESTRUCTIVE  set to any value to also deny irreversible data/infra
#                            shell commands (DROP/TRUNCATE, unbounded DELETE, Redis
#                            FLUSHALL/FLUSHDB, NATS stream/consumer teardown,
#                            rm -rf on an absolute/home path). Tune per stack.
#
# NOTE: VS Code ignores hook "matchers", so this script fires on EVERY tool call
# and branches on tool_name itself. Tool names / input keys differ across
# surfaces — VS Code: create_file / replace_string_in_file, camelCase
# tool_input.filePath; Claude/CLI: Write / Edit, snake_case file_path. Both are
# handled below.
set -eufo pipefail   # -f: no globbing (path prefixes are literal, never patterns)

input="$(cat)"
tool="$(jq -r '.tool_name // empty' <<<"$input")"

deny() {
  jq -nc --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

case "$tool" in
  create_file | replace_string_in_file | multi_replace_string_in_file | edit_notebook_file | Write | Edit | MultiEdit)
    # Collect every target path this edit touches, across surface variants.
    paths="$(jq -r '
      [ .tool_input.filePath?,
        .tool_input.file_path?,
        (.tool_input.replacements[]?.filePath),
        (.tool_input.edits[]?.file_path) ]
      | map(select(. != null and . != "")) | .[]' <<<"$input")"
    [ -z "$paths" ] && exit 0

    while IFS= read -r p; do
      [ -z "$p" ] && continue
      rel="${p#"$PWD"/}"   # absolute (VS Code) -> workspace-relative; no-op if already relative

      # Frozen entrypoints: never editable by any track (tracks self-register).
      saved_ifs="$IFS"; IFS=:
      for f in ${TRACK_FROZEN_PATHS:-}; do
        [ "$rel" = "$f" ] && { IFS="$saved_ifs";
          deny "frozen entrypoint '$rel' — self-register via your track's own file instead of editing the shared entrypoint"; }
      done
      IFS="$saved_ifs"

      # Deny-by-default: the path MUST match an allowed prefix.
      ok=0
      saved_ifs="$IFS"; IFS=:
      for a in ${TRACK_ALLOWED_PREFIXES:-}; do
        case "$rel" in "$a"*) ok=1 ;; esac
      done
      IFS="$saved_ifs"
      [ "$ok" -eq 1 ] ||
        deny "'$rel' is outside this track's ownership scope (set TRACK_ALLOWED_PREFIXES); editing it would become a merge conflict at integration"

      # Generated files are never hand-edited — re-run the generator (always-on).
      if [ -f "$rel" ] && head -3 "$rel" 2>/dev/null | grep -q "GENERATED — DO NOT EDIT"; then
        deny "'$rel' is generated (carries a 'GENERATED — DO NOT EDIT' banner) — re-run its generator instead of editing it by hand"
      fi

      # Immutable prefixes: an already-committed file (e.g. an applied migration)
      # is append-only. A brand-new file under the prefix is allowed.
      saved_ifs="$IFS"; IFS=:
      for m in ${TRACK_IMMUTABLE_PREFIXES:-}; do
        case "$rel" in
          "$m"*)
            if git log --oneline -1 -- "$rel" 2>/dev/null | grep -q .; then
              IFS="$saved_ifs"
              deny "'$rel' is an already-committed artifact under an immutable prefix ($m) — create a NEW file instead of editing it"
            fi ;;
        esac
      done
      IFS="$saved_ifs"
    done <<<"$paths"
    ;;

  run_in_terminal | bash | shell)
    cmd="$(jq -r '.tool_input.command // .tool_input.bash // empty' <<<"$input")"
    # Workers stop at the draft PR. No pushes, merges, history rewrites, or gate bypass.
    case "$cmd" in
      *"git push"* | *"gh pr merge"* | *"git merge "* | *"--force"* | *"--no-verify"* | *"git reset --hard"*)
        deny "blocked by autonomy boundary: workers stop at 'gh pr create --draft'. Pushing/merging/rewriting history is the merge gate's job (human or merge queue), not the worker's." ;;
    esac

    # OPTIONAL destructive-infra guard — irreversible data/infra ops. Off unless
    # TRACK_GUARD_DESTRUCTIVE is set; case-insensitive; tune patterns per stack.
    if [ -n "${TRACK_GUARD_DESTRUCTIVE:-}" ]; then
      shopt -s nocasematch
      case "$cmd" in
        *"drop table"* | *"drop database"* | *"drop schema"* | *truncate*)
          deny "blocked: irreversible schema op in '$cmd'. Express it as a reversible migration, not an ad-hoc DROP/TRUNCATE." ;;
        *flushall* | *flushdb*)
          deny "blocked: Redis FLUSHALL/FLUSHDB wipes shared state. Scope deletions to your own keys instead." ;;
        *"nats stream rm"* | *"nats stream delete"* | *"nats stream purge"* | *"nats consumer rm"* | *"nats consumer delete"*)
          deny "blocked: NATS stream/consumer teardown touches shared infra. Leave topology changes to the platform owner." ;;
        *"rm -rf /"* | *"rm -fr /"* | *"rm -rf ~"* | *"rm -fr ~"*)
          deny "blocked: 'rm -rf' on an absolute or home path. Delete only within the repo/worktree." ;;
      esac
      # Unbounded DELETE (no WHERE) wipes a whole table.
      case "$cmd" in
        *"delete from"*)
          case "$cmd" in
            *where*) : ;;
            *) deny "blocked: 'DELETE FROM' with no WHERE clause wipes the whole table. Add a WHERE filter." ;;
          esac ;;
      esac
      shopt -u nocasematch
    fi
    ;;
esac

exit 0
