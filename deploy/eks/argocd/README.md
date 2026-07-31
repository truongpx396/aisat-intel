# Argo CD — GitOps for the app + observability stack

Argo CD watches this repo and reconciles from Git. It owns two things:

1. **The aisat app** ([apps/aisat-app.yaml](./apps/aisat-app.yaml)) — the Helm chart
   in [../helm/aisat](../helm/aisat). This **replaces** the CI `helm upgrade`:
   [cd-eks.yml](../../../.github/workflows/cd-eks.yml) now builds+pushes images and
   commits the new tag; Argo CD rolls it out. See **[Deploying the app](#deploying-the-app)**.
2. **The observability stack** ([apps/](./apps)) — the **GitOps alternative** to the
   Terraform-managed Helm releases in [../terraform/monitoring.tf](../terraform/monitoring.tf)
   and [../terraform/langfuse.tf](../terraform/langfuse.tf): the same charts, driven
   by Git instead of `terraform apply`.

> **Pick one owner per component.** Don't have both Terraform *and* Argo CD manage
> the same chart. If you use this GitOps path, set the Terraform stack toggles to
> `false` (keep `enable_argocd = true`):
>
> ```hcl
> enable_kube_prometheus_stack = false
> enable_loki                  = false
> enable_tempo                 = false
> enable_langfuse              = false
> ```

## Layout

```
argocd/
  projects/aisat.yaml           # AppProject (scopes repos/namespaces/resources)
  root-app.yaml                 # app-of-apps — syncs everything under apps/
  apps/
    aisat-app.yaml              # the aisat application (../helm/aisat chart)
    kube-prometheus-stack.yaml  # Prometheus + Alertmanager + Grafana + exporters
    loki.yaml                   # logs
    tempo.yaml                  # traces (OTLP)
    langfuse.yaml               # LLM tracing/eval + bundled Postgres
```

## Deploying the app

`aisat-app.yaml` renders [../helm/aisat](../helm/aisat) with three committed value
files (later wins):

| File | Owner | Holds |
| --- | --- | --- |
| [values-production.yaml](../helm/aisat/values-production.yaml) | you | prod tuning (replicas, External Secrets) |
| [values-eks.yaml](../helm/aisat/values-eks.yaml) | you (fill once) | `image.registry`, `ingress.host`, `certificateArn`, `migrate.hookProvider: argocd` |
| [values-image.yaml](../helm/aisat/values-image.yaml) | **CI** | just `image.tag` — rewritten by [cd-eks.yml](../../../.github/workflows/cd-eks.yml) each release |

**Release flow (one owner — Argo CD, not `helm upgrade`):**

```
push tag / dispatch → build+push to ECR → [production-eks approval]
   → CI writes image.tag to values-image.yaml + git push
       → Argo CD detects the commit → sync
           → migrate Sync hook (wave -1) → app rollout (wave 0)
```

**Migrations & ordering.** With `migrate.hookProvider: argocd`, the migrate Job is
an Argo **Sync hook** (deleted+recreated each sync, so it re-runs every deploy).
[sync-waves](../helm/aisat/templates) order the sync: infra (config/Secret/DB) at
**-2**, migrate at **-1**, app at **0** — so the very first sync doesn't deadlock
waiting on a DB that hasn't synced yet. The migrate initContainer still blocks on
`migrate.waitFor.host`; for a managed DB point it at RDS (or set it to `""`).

**Rollback** is a Git operation: revert the `values-image.yaml` commit (or set an
earlier tag) and Argo CD syncs back. Or `argocd app rollback aisat-app <id>`.

**Before the first sync:** fill `values-eks.yaml`, set up **External Secrets** +
the `ClusterSecretStore` (production values expect ESO — see [../SETUP.md](../SETUP.md)),
and ensure CI can push to the branch Argo tracks (see the token/branch note in
[cd-eks.yml](../../../.github/workflows/cd-eks.yml)).

> **Break-glass:** to deploy by hand while Argo owns the app, pause auto-sync first
> (`argocd app set aisat-app --sync-policy none`) or self-heal will revert you.

Each app under `apps/` is a Helm-chart `Application`; the app-of-apps
(`root-app.yaml`) points Argo CD at the `apps/` directory so adding a file there
adds a managed component.

## Bootstrap

Argo CD itself is installed by Terraform (`enable_argocd = true`). Once it's up:

```bash
# 0) point spec.source.repoURL in root-app.yaml at your repo (and register repo
#    credentials in Argo CD first if the repo is private).

# 1) pre-create the secrets the apps reference (never inline secrets in Git):
kubectl create namespace monitoring 2>/dev/null || true
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -hex 24)"

kubectl create namespace langfuse 2>/dev/null || true
kubectl -n langfuse create secret generic langfuse-secrets \
  --from-literal=nextauth-secret="$(openssl rand -hex 32)" \
  --from-literal=salt="$(openssl rand -hex 32)" \
  --from-literal=postgres-password="$(openssl rand -hex 32)"

# 2) apply the project + app-of-apps:
kubectl apply -f projects/aisat.yaml
kubectl apply -f root-app.yaml

# 3) watch it converge:
kubectl -n argocd get applications -w
```

## Reach the UIs (port-forward)

```bash
# Argo CD (admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
kubectl -n argocd port-forward svc/argocd-server 8080:443      # https://localhost:8080

# Grafana / Prometheus
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

## App wiring

- **Traces** — set `OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo.monitoring.svc:4318`
  in the app's config/secret.
- **Metrics** — expose `/metrics` and add a `ServiceMonitor` (Prometheus watches
  all namespaces — see `serviceMonitorSelectorNilUsesHelmValues: false`).
- **LLM traces** — set `LANGFUSE_HOST` to the in-cluster Langfuse service.

## Notes

- Chart `targetRevision`s mirror the Terraform variable defaults. **Verify/bump**
  them against the upstream chart indexes; keep the two paths in sync if you run both.
- `ServerSideApply=true` on kube-prometheus-stack avoids the "annotation too long"
  problem its large CRDs otherwise hit.
