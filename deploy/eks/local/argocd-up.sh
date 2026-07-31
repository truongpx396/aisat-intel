#!/usr/bin/env bash
# OPTIONAL: run Argo CD on the local Kind cluster and let it reconcile the
# observability app-of-apps (deploy/eks/argocd). On real EKS, Terraform installs
# Argo CD; here we install it directly. Run up.sh first (needs the cluster).
#
# HEAVY: this brings up kube-prometheus-stack + Loki + Tempo + Langfuse. Give
# Docker >= 8 GB RAM or expect pods to stay Pending/OOM.
#
# KEY CAVEAT: Argo CD syncs the app manifests from GitHub, NOT your local disk.
# It reads deploy/eks/argocd/apps at the target git revision, so that ref must be
# PUSHED and must contain those files. Defaults to your current branch; override
# with ARGOCD_TARGET_REVISION=main (or any pushed ref).
#
# SCOPE: the app-of-apps also contains aisat-app (the application), but that overlay
# is AWS-wired (ECR images, External Secrets, ALB) and can't run on Kind — so this
# script EXCLUDES it and syncs only the observability stack. Deploy the app locally
# with up.sh (Helm). Set LOCAL_ARGO_INCLUDE_APP=1 to keep it in (it will stay
# OutOfSync/Degraded on Kind — expected).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGO_DIR="$HERE/../argocd"
CLUSTER="${KIND_CLUSTER:-aisat}"
REV="${ARGOCD_TARGET_REVISION:-$(git -C "$HERE" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"

# --with-app: also deploy the aisat app via Argo CD using the Kind overlay
# (argocd-app-kind.yaml) — full GitOps parity, no AWS. Default: observability only.
WITH_APP=0
for arg in "$@"; do
  case "$arg" in
    --with-app) WITH_APP=1 ;;
    *) echo "unknown argument: $arg (supported: --with-app)" >&2; exit 1 ;;
  esac
done

for bin in kubectl openssl git; do
  command -v "$bin" >/dev/null || { echo "'$bin' not found on PATH"; exit 1; }
done
if [ "$WITH_APP" = "1" ]; then
  for bin in helm docker kind; do
    command -v "$bin" >/dev/null || { echo "'$bin' not found (needed for --with-app)"; exit 1; }
  done
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "==> gp3 StorageClass alias (so the observability PVCs bind on Kind)"
kubectl apply -f "$HERE/gp3-storageclass.yaml"

echo "==> installing Argo CD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
echo "    waiting for argocd-server..."
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

echo "==> pre-creating the secrets the observability apps reference"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -hex 24)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace langfuse --dry-run=client -o yaml | kubectl apply -f -
kubectl -n langfuse create secret generic langfuse-secrets \
  --from-literal=nextauth-secret="$(openssl rand -hex 32)" \
  --from-literal=salt="$(openssl rand -hex 32)" \
  --from-literal=postgres-password="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> applying AppProject + app-of-apps (target revision: $REV)"
kubectl apply -f "$ARGO_DIR/projects/aisat.yaml"
kubectl apply -f "$ARGO_DIR/root-app.yaml"
# Point Argo CD at a ref that actually contains deploy/eks/argocd/apps, and (unless
# opted in) exclude the AWS-wired app so only the observability stack syncs on Kind.
if [ "${LOCAL_ARGO_INCLUDE_APP:-0}" = "1" ]; then
  echo "    (LOCAL_ARGO_INCLUDE_APP=1 — keeping aisat-app; expect it OutOfSync on Kind)"
  kubectl -n argocd patch application aisat-observability-root --type merge \
    -p "{\"spec\":{\"source\":{\"targetRevision\":\"$REV\"}}}"
else
  kubectl -n argocd patch application aisat-observability-root --type merge \
    -p "{\"spec\":{\"source\":{\"targetRevision\":\"$REV\",\"directory\":{\"exclude\":\"aisat-app.yaml\"}}}}"
fi

if [ "$WITH_APP" = "1" ]; then
  echo "==> --with-app: deploying the aisat app via Argo CD (Kind overlay)"
  # Argo CD can't co-own resources a Helm release already manages.
  if helm -n aisat status aisat >/dev/null 2>&1; then
    echo "ERROR: a Helm release 'aisat' exists in namespace 'aisat' (from up.sh)." >&2
    echo "       Argo CD cannot co-own it. Remove it first:" >&2
    echo "         helm -n aisat uninstall aisat" >&2
    echo "       or re-run up.sh with INSTALL_APP=none so Helm skips the app." >&2
    exit 1
  fi
  # Make sure the app images exist in the cluster (up.sh normally loads them).
  if ! docker image inspect aisat.local/aisat-backend-go:dev >/dev/null 2>&1; then
    echo "    app images not found — building + loading into Kind..."
    "$HERE/build-load.sh"
  fi
  kubectl apply -f "$HERE/argocd-app-kind.yaml"
  kubectl -n argocd patch application aisat-app-kind --type merge \
    -p "{\"spec\":{\"source\":{\"targetRevision\":\"$REV\"}}}"
  echo "    aisat-app-kind applied (revision $REV)."
fi

PW='kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='"'"'{.data.password}'"'"' | base64 -d; echo'
echo
echo "-------------------------------------------------------------------"
echo "Argo CD up. It reconciles from git ref: $REV  (must be pushed!)"
echo "  admin password:  $PW"
echo "  open the UI:      kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080  (user: admin)"
echo "  watch it sync:    kubectl -n argocd get applications -w"
if [ "$WITH_APP" = "1" ]; then
echo "  app rollout:      kubectl -n aisat get pods -w         # migrate Sync hook (wave -1) runs first"
echo "  app URL:          http://aisat.localtest.me/           # once aisat-app-kind is Healthy"
fi
echo "  Grafana:          kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80   # http://localhost:3000"
echo "-------------------------------------------------------------------"
