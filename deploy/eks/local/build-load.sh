#!/usr/bin/env bash
# Build the four app images from their Dockerfiles and load them into the Kind
# cluster, tagged so the chart's "{registry}/{prefix}-{repo}:{tag}" ref resolves.
# Overridable: LOCAL_REGISTRY, IMAGE_PREFIX, IMAGE_TAG, KIND_CLUSTER. Keep these
# in sync with deploy/eks/local/values-kind.yaml (image.registry/prefix/tag).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CLUSTER="${KIND_CLUSTER:-aisat}"
REG="${LOCAL_REGISTRY:-aisat.local}"
PREFIX="${IMAGE_PREFIX:-aisat}"
TAG="${IMAGE_TAG:-dev}"

command -v docker >/dev/null || { echo "docker not found"; exit 1; }
command -v kind   >/dev/null || { echo "kind not found"; exit 1; }

build() { # <repo-name> <context> [dockerfile]
  local name="$1" ctx="$2" df="${3:-}"
  local ref="$REG/$PREFIX-$name:$TAG"
  echo "==> build $ref"
  if [ -n "$df" ]; then
    docker build -f "$df" -t "$ref" "$ctx"
  else
    docker build -t "$ref" "$ctx"
  fi
  echo "==> kind load $ref"
  kind load docker-image "$ref" --name "$CLUSTER"
}

build backend-go     "$ROOT/backend-go"
build backend-python "$ROOT/backend-python"
build crawl          "$ROOT/backend-python" "$ROOT/backend-python/Dockerfile.crawl"
build frontend       "$ROOT/frontend"

echo "==> loaded: $REG/$PREFIX-{backend-go,backend-python,crawl,frontend}:$TAG"
