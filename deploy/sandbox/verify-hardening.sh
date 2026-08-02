#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Assert the sandbox hardening invariants against the RENDERED compose config.
#
# These are contract obligations from
#   specs/001-contextengine-mvp/contracts/sandbox-runtime.md
# and every one of them FAILS SILENTLY in normal operation — a sandbox that
# quietly gained a secret, a writable rootfs, or a bind mount looks perfectly
# healthy while violating the design. So they are checked mechanically, against
# the rendered config rather than the source YAML, because anchors/extends/
# profiles mean the source is not what actually runs.
#
#   make sandbox-verify
#
# Exits non-zero on the first violated invariant.
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0
note() { printf '  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }

render() { # $1 = compose file, $2... = extra args
  local f="$1"; shift
  docker compose -f "$f" "$@" config --format json 2>/dev/null || true
}

check_file() {
  local label="$1" json="$2"
  printf '\n== %s ==\n' "$label"
  if [ -z "$json" ] || [ "$json" = "null" ]; then
    note "skipped (could not render — missing env or docker unavailable)"
    return
  fi
  SANDBOX_JSON="$json" python3 - <<'PY'
import json, os, re, sys

doc = json.loads(os.environ["SANDBOX_JSON"])
svcs = doc.get("services", {})
rc = 0
def bad(m):
    global rc; print(f"  \033[31mFAIL\033[0m {m}"); rc = 1
def ok(m):
    print(f"  \033[32mok\033[0m   {m}")

# --- invariant 8: no runtime socket ANYWHERE in the stack, not just sandboxes
sock = []
for name, s in svcs.items():
    for v in s.get("volumes", []) or []:
        src = v.get("source", "") if isinstance(v, dict) else str(v)
        if "docker.sock" in src or "containerd.sock" in src or "crio.sock" in src:
            sock.append(name)
if sock:
    bad(f"invariant 8: runtime socket mounted into {sorted(set(sock))}")
else:
    ok("invariant 8: no container-runtime socket mounted in any service")

sandboxes = {n: s for n, s in svcs.items() if n.startswith("sandbox-")}
if not sandboxes:
    print("  (no sandbox-* services in this file)")
    sys.exit(rc)

SECRET = re.compile(
    r"(API_KEY|PASSWORD|SECRET|TOKEN|DATABASE_URL|_DSN|PRIVATE_KEY)", re.I)
ALLOWED_SECRETS = {"SANDBOX_API_KEY"}   # authenticates INBOUND calls; not a provider key

for name, s in sorted(sandboxes.items()):
    # --- invariant 1: no ambient credentials -------------------------------
    env = s.get("environment", {}) or {}
    if isinstance(env, list):
        env = dict(e.split("=", 1) for e in env if "=" in e)
    leaked = sorted(k for k in env if SECRET.search(k) and k not in ALLOWED_SECRETS)
    if leaked:
        bad(f"{name}: invariant 1 — ambient credentials present: {leaked}")
    elif len(env) > 12:
        bad(f"{name}: invariant 1 — {len(env)} env vars suggests an inherited env_file; enumerate instead")
    else:
        ok(f"{name}: invariant 1 — {len(env)} env vars, no ambient credentials")

    # --- invariant 10: no bind mounts / volumes of any kind ----------------
    vols = s.get("volumes", []) or []
    if vols:
        bad(f"{name}: invariant 10 — {len(vols)} volume(s) mounted; files must move via S3 staging")
    else:
        ok(f"{name}: invariant 10 — no volumes")

    # --- pod/container hardening -------------------------------------------
    problems = []
    if not s.get("read_only"):
        problems.append("read_only not set (invariant 12: a restart reuses the writable layer)")
    if str(s.get("user", "")).startswith(("0:", "root")) or not s.get("user"):
        problems.append("not pinned to a non-root user")
    if "ALL" not in (s.get("cap_drop") or []):
        problems.append("cap_drop: [ALL] missing")
    if not any("no-new-privileges" in str(o) for o in (s.get("security_opt") or [])):
        problems.append("no-new-privileges missing")
    if not s.get("pids_limit"):
        problems.append("pids_limit unset (a mem cap without a PID cap is not a cap)")
    if not s.get("tmpfs"):
        problems.append("no tmpfs — a read-only rootfs needs one writable scratch path")
    else:
        for t in s.get("tmpfs") or []:
            if "noexec" not in str(t):
                problems.append(f"tmpfs {t!r} is not noexec")
    if problems:
        for p in problems:
            bad(f"{name}: {p}")
    else:
        ok(f"{name}: hardened (read_only, non-root, caps dropped, no-new-privs, pids, noexec tmpfs)")

    # --- oneshot-specific: tmpl-coderun ------------------------------------
    if "coderun" in name:
        if env.get("SANDBOX_KIND") != "oneshot":
            bad(f"{name}: SANDBOX_KIND must be 'oneshot' (never 'service' — reset is not destruction)")
        elif str(env.get("SANDBOX_MAX_RUNS")) != "1":
            bad(f"{name}: SANDBOX_MAX_RUNS must be 1 — an instance that ran model-authored code is never reused")
        elif s.get("restart") != "always":
            bad(f"{name}: restart must be 'always' — it IS the recreate mechanism after each exit")
        else:
            ok(f"{name}: oneshot — kind=oneshot, max_runs=1, restart=always")

sys.exit(rc)
PY
}

echo "Sandbox hardening verification"
echo "  contract: specs/001-contextengine-mvp/contracts/sandbox-runtime.md"

check_file "local (deploy/sandbox/docker-compose.sandbox.yml)" \
  "$(render deploy/sandbox/docker-compose.sandbox.yml --profile coderun)" || fail=1

if [ -f deploy/do/.env.production ]; then
  check_file "production (deploy/do/docker-compose.prod.yml)" \
    "$(render deploy/do/docker-compose.prod.yml --profile coderun)" || fail=1
else
  printf '\n== production (deploy/do/docker-compose.prod.yml) ==\n'
  note "skipped — deploy/do/.env.production not present (expected on a dev machine)"
fi

printf '\n'
if [ "$fail" -ne 0 ]; then
  echo "FAILED — see above. These invariants fail silently in production; do not merge past them."
  exit 1
fi
echo "All sandbox hardening invariants hold."
