#!/usr/bin/env bash
# Tear down the local Kind cluster (everything in it — app, Argo CD, observability).
set -euo pipefail
CLUSTER="${KIND_CLUSTER:-aisat}"
kind delete cluster --name "$CLUSTER"
