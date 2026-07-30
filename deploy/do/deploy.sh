#!/usr/bin/env bash
# Remote deploy — runs ON the droplet, invoked by the CD pipeline over SSH.
# Pulls the SHA-tagged images, migrates, brings the stack up, health-checks,
# and rolls back to the previous tag if the new one is unhealthy.
#
# Required env (exported by the CD job): IMAGE_TAG, DOCKERHUB_USERNAME
# Optional (defaulted):                  REGISTRY=docker.io, IMAGE_PREFIX=aisat
set -euo pipefail

cd "$(dirname "$0")"

export REGISTRY="${REGISTRY:-docker.io}"
export IMAGE_PREFIX="${IMAGE_PREFIX:-aisat}"
: "${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"

[ -f .env.production ] || { echo "ERROR: .env.production missing on the droplet (see bootstrap-droplet.sh)"; exit 1; }

# Optionally fold in the observability overlay (Prometheus/Grafana/Loki/Tempo/
# Alertmanager/exporters/Langfuse). Set ENABLE_MONITORING=true in the CD job env.
COMPOSE_FILES=(-f docker-compose.prod.yml)
if [ "${ENABLE_MONITORING:-false}" = "true" ]; then
  COMPOSE_FILES+=(-f monitoring/docker-compose.monitoring.yml)
fi

COMPOSE=(docker compose "${COMPOSE_FILES[@]}" --env-file .env.production)
HEALTH_SVC="go-api"          # gate the rollout on the BFF becoming healthy
HEALTH_TIMEOUT=180           # seconds
PREV_FILE=".last_deployed_tag"

log() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }

wait_healthy() {
  local svc="$1" deadline=$(( SECONDS + HEALTH_TIMEOUT )) cid status
  cid="$("${COMPOSE[@]}" ps -q "$svc" || true)"
  [ -n "$cid" ] || { echo "no container for $svc"; return 1; }
  while [ "$SECONDS" -lt "$deadline" ]; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
    case "$status" in
      healthy) return 0 ;;
      none) echo "$svc has no healthcheck — treating 'running' as ready"; \
            [ "$(docker inspect -f '{{.State.Running}}' "$cid")" = "true" ] && return 0 ;;
    esac
    sleep 5
  done
  return 1
}

log "Logged-in registry: ${REGISTRY} as ${DOCKERHUB_USERNAME} (tag ${IMAGE_TAG})"
[ "${ENABLE_MONITORING:-false}" = "true" ] && log "Monitoring overlay ENABLED (Prometheus/Grafana/Loki/Tempo/Alertmanager)"

log "Pulling images @ ${IMAGE_TAG}"
IMAGE_TAG="$IMAGE_TAG" "${COMPOSE[@]}" pull

log "Running database migrations"
if ! IMAGE_TAG="$IMAGE_TAG" "${COMPOSE[@]}" --profile migrate run --rm migrate; then
  echo "ERROR: migrations failed — aborting before touching running services."
  exit 1
fi

log "Starting / updating services"
IMAGE_TAG="$IMAGE_TAG" "${COMPOSE[@]}" up -d --remove-orphans

log "Waiting for '${HEALTH_SVC}' to become healthy (<= ${HEALTH_TIMEOUT}s)"
if wait_healthy "$HEALTH_SVC"; then
  echo "$IMAGE_TAG" > "$PREV_FILE"
  log "Deploy OK. Pruning dangling images."
  docker image prune -f >/dev/null 2>&1 || true
  echo "Deployed ${IMAGE_TAG}."
  exit 0
fi

echo "ERROR: '${HEALTH_SVC}' did not become healthy."
if [ -f "$PREV_FILE" ]; then
  prev="$(cat "$PREV_FILE")"
  if [ -n "$prev" ] && [ "$prev" != "$IMAGE_TAG" ]; then
    log "Rolling back to ${prev}"
    IMAGE_TAG="$prev" "${COMPOSE[@]}" up -d --remove-orphans || true
  fi
fi
exit 1
