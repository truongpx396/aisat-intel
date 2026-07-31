# Local EKS-chart testing on Kind

Exercise the **portable** part of the EKS deploy path ([../helm/aisat](../helm/aisat))
on a local [Kind](https://kind.sigs.k8s.io) cluster — no AWS account, no cost. This
is for validating the **Helm chart and Kubernetes manifests**: template rendering,
workload wiring, service DNS, probes, the migrate hook, PVCs. For app *logic*, the
compose stack ([../../do](../../do)) is a faster loop.

> **Kind vs. "Kind + EKS Distro":** EKS-D only gives you Kubernetes *version* parity
> — the same upstream binaries EKS runs. It does **not** provide the AWS cloud
> integrations (ALB controller, EBS CSI, IRSA/OIDC, ECR auth), which is exactly
> what's AWS-specific here. So for validating this chart, plain Kind is as good;
> reach for EKS-D node images only if you're chasing a k8s-version-specific bug.

## What this reproduces vs. fakes vs. can't do

| Surface | On real EKS | Locally |
| --- | --- | --- |
| App Deployments, backing StatefulSets, Services, ConfigMaps, migrate hook, probes, PVCs | ✅ | ✅ faithfully |
| Ingress | ALB (`className: alb`) + ACM TLS | ingress-nginx, HTTP only |
| Images | ECR pull via node IAM | built + `kind load`ed |
| Storage | `gp3` (EBS CSI) | `gp3` aliased to Kind local-path |
| App secrets | External Secrets ← AWS Secrets Manager | chart-rendered inline Secret |
| Pod AWS access | IRSA / OIDC | **not reproducible** — no IAM |
| VPC / EKS / RDS / ElastiCache / OIDC role ([../terraform](../terraform)) | Terraform | **not exercised at all** |

The bottom two rows have no local analogue — test them on a throwaway real EKS
cluster. Everything above is what Kind is good for.

## Prerequisites

`docker`, [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation),
`kubectl`, `helm`. Give Docker **≥ 4 GB** for the app alone, **≥ 8 GB** if you also
run the Argo CD observability stack.

## Quick start

```bash
deploy/eks/local/up.sh          # cluster + ingress-nginx + build/load images + helm install
# open http://aisat.localtest.me/   (*.localtest.me -> 127.0.0.1)
deploy/eks/local/down.sh        # delete the whole cluster
```

Useful env overrides (all optional): `KIND_CLUSTER`, `NAMESPACE`, `IMAGE_TAG`,
`INGRESS_NGINX_REF`. Re-running `up.sh` reuses an existing cluster and re-applies
the release (safe to run after code changes — it rebuilds + reloads the images).

Iterating on the chart without rebuilding images:

```bash
helm upgrade aisat deploy/eks/helm/aisat -n aisat -f deploy/eks/local/values-kind.yaml
```

## Argo CD (optional) — GitOps for the observability stack

```bash
deploy/eks/local/argocd-up.sh   # after up.sh
```

Argo CD runs perfectly on Kind and will reconcile the app-of-apps in
[../argocd](../argocd) → Prometheus + Grafana + Loki + Tempo + Langfuse. Two things
to keep straight:

- **Two kinds of "monitoring".** Argo CD monitors *sync/drift* of the Applications.
  The stack it deploys (Prometheus/Grafana) is what monitors the cluster's *runtime*
  metrics/logs/traces — and yes, it scrapes your local Kind nodes and pods fine.
- **Argo CD syncs from GitHub, not your working tree.** It reads
  `deploy/eks/argocd/apps` at a **pushed** git ref. The script defaults that ref to
  your current branch; override with `ARGOCD_TARGET_REVISION=main`. Local
  uncommitted edits to those app manifests won't be seen until you push.

**The app vs. the app-of-apps.** In production, Argo CD deploys *both* the app
([apps/aisat-app.yaml](../argocd/apps/aisat-app.yaml)) and the observability stack.
But `aisat-app` is AWS-wired (ECR images, External Secrets, ALB) and can't run on
Kind, so `argocd-up.sh` **excludes it** and syncs observability only — you deploy
the app locally with `up.sh` (Helm), which stands in for Argo's role. To keep it in
anyway (it'll sit OutOfSync/Degraded on Kind), run `LOCAL_ARGO_INCLUDE_APP=1
argocd-up.sh`.

### Full GitOps parity — let Argo CD deploy the app on Kind

To watch Argo CD run the **exact prod flow** locally (migrate Sync hook at wave -1,
then rollout), use the Kind overlay app ([argocd-app-kind.yaml](./argocd-app-kind.yaml)) —
same chart, but `values-kind.yaml` + `migrate.hookProvider: argocd` instead of the
AWS overlay. Helm must NOT also own the app, so prep the cluster without installing it:

```bash
INSTALL_APP=none deploy/eks/local/up.sh     # cluster + ingress + built/loaded images, NO helm app
git push                                     # Argo reads the chart + values-kind.yaml from Git, not disk
deploy/eks/local/argocd-up.sh --with-app     # Argo CD deploys the app (+ observability)
```

`--with-app` refuses to run if a Helm release `aisat` already exists (that would
double-own the objects). Then watch the hook + rollout:

```bash
kubectl -n argocd get applications -w        # aisat-app-kind -> Synced/Healthy
kubectl -n aisat  get pods -w                # aisat-migrate (hook) runs first, then the app
# open http://aisat.localtest.me/
```

This works on Kind because the sync-waves bring up the in-cluster Postgres/Secret
(wave -2) before the migrate hook (wave -1) — no RDS/ESO needed. Still **pushed-Git
only**: local edits to the chart or `values-kind.yaml` aren't seen until you push.

Access after it converges:

```bash
kubectl -n argocd get applications -w
kubectl -n argocd port-forward svc/argocd-server 8080:443           # https://localhost:8080 (admin)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80   # http://localhost:3000
```

## Files

| File | Purpose |
| --- | --- |
| `up.sh` / `down.sh` | bring the app stack up / tear the cluster down |
| `build-load.sh` | build the 4 app images and `kind load` them |
| `values-kind.yaml` | chart overrides (nginx ingress, local-path, inline Secret, no IRSA) |
| `kind-cluster.yaml` | Kind config (ingress-ready node, host ports 80/443) |
| `gp3-storageclass.yaml` | `gp3` → local-path alias so hardcoded gp3 PVCs bind |
| `argocd-up.sh` | optional: install Argo CD + observability app-of-apps (`--with-app` also deploys the app) |
| `argocd-app-kind.yaml` | Kind-overlay Argo CD Application for the app (full GitOps parity) |
