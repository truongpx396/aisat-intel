#!/usr/bin/env bash
# One-command local bring-up of the aisat EKS Helm chart on Kind:
#   1. create the Kind cluster (host ports 80/443 published)
#   2. add the gp3 StorageClass alias
#   3. install ingress-nginx (Kind provider)
#   4. build + load the app images
#   5. helm upgrade --install with values-kind.yaml
#
# Overridable env: KIND_CLUSTER, HELM_RELEASE, NAMESPACE, INGRESS_NGINX_REF,
# and the image vars honoured by build-load.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$HERE/../helm/aisat"
CLUSTER="${KIND_CLUSTER:-aisat}"
RELEASE="${HELM_RELEASE:-aisat}"
NS="${NAMESPACE:-aisat}"
INGRESS_NGINX_REF="${INGRESS_NGINX_REF:-controller-v1.11.3}"
HOST="$(awk '/^  host:/ {print $2; exit}' "$HERE/values-kind.yaml")"
# How the app is deployed: 'helm' (default, this script installs it) or 'none'
# (prep the cluster + images only, then deploy via argocd-up.sh --with-app).
INSTALL_APP="${INSTALL_APP:-helm}"

for bin in kind kubectl helm docker; do
  command -v "$bin" >/dev/null || { echo "'$bin' not found on PATH"; exit 1; }
done

echo "==> [1/5] Kind cluster '$CLUSTER'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "    already exists — reusing"
else
  kind create cluster --name "$CLUSTER" --config "$HERE/kind-cluster.yaml"
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

echo "==> [2/5] gp3 StorageClass alias"
kubectl apply -f "$HERE/gp3-storageclass.yaml"

echo "==> [3/5] ingress-nginx ($INGRESS_NGINX_REF)"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_REF}/deploy/static/provider/kind/deploy.yaml"
echo "    waiting for the controller to be ready..."
kubectl -n ingress-nginx wait --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller --timeout=180s || \
  echo "    (controller not ready yet — continuing; check: kubectl -n ingress-nginx get pods)"

echo "==> [4/5] build + load app images"
"$HERE/build-load.sh"

if [ "$INSTALL_APP" = "helm" ]; then
  echo "==> [5/5] helm upgrade --install $RELEASE"
  helm upgrade --install "$RELEASE" "$CHART" \
    --namespace "$NS" --create-namespace \
    -f "$HERE/values-kind.yaml" \
    --wait --timeout 12m || \
    echo "    helm --wait timed out or failed; the stack may still be converging."
else
  echo "==> [5/5] INSTALL_APP=$INSTALL_APP — skipping the Helm app install."
  echo "    Let Argo CD own the app instead:  $HERE/argocd-up.sh --with-app"
fi

echo
echo "-------------------------------------------------------------------"
if [ "$INSTALL_APP" = "helm" ]; then
echo "Pods:   kubectl -n $NS get pods"
echo "App:    http://$HOST/            (ingress-nginx -> frontend/Caddy)"
echo "        If port 80 is taken, run: kubectl -n $NS port-forward svc/frontend 8080:80"
echo "        then open http://localhost:8080/"
else
echo "App:    not installed (INSTALL_APP=$INSTALL_APP)."
echo "        Deploy via Argo CD:  $HERE/argocd-up.sh --with-app"
fi
echo "Down:   $HERE/down.sh"
echo "Argo CD: $HERE/argocd-up.sh            # observability stack (GitOps)"
echo "         $HERE/argocd-up.sh --with-app # + the app itself (full GitOps parity)"
echo "-------------------------------------------------------------------"
