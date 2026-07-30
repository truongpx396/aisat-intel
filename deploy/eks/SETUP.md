# CI/CD Setup — GitHub Actions → Amazon ECR → AWS EKS (Helm, OIDC, Telegram alerts)

This is the **AWS EKS** deploy path. It runs **alongside** the DigitalOcean droplet
pipeline ([../SETUP.md](../SETUP.md)) — nothing here replaces that. Same app images,
different target: a Helm release on an EKS cluster fronted by an ALB.

```
 push tag / dispatch ─► CD (EKS)  preflight ─► build+push images (ECR, SBOM+provenance)  [cd-eks.yml]
                                   └─► ⛔ approval gate (production-eks environment)
                                        └─► helm upgrade ─► migrate hook ─► rollout
                                             └─► --atomic rollback on failure ─► Telegram ✅/❌
 Terraform (deploy/eks/terraform) ─► VPC · EKS · node group · IRSA · ECR · ALB controller · OIDC role
```

Auth is **OIDC-only** — the workflow assumes a scoped AWS role at run time; there
are **no long-lived AWS keys** in GitHub secrets.

---

## 1. Provision the cluster (Terraform)

See [terraform/README.md](./terraform/README.md) for the full walkthrough. In short:

```bash
cd deploy/eks/terraform
cp terraform.tfvars.example terraform.tfvars   # set region, cluster_name, github_*, ...
export AWS_PROFILE=aisat
terraform init && terraform apply
$(terraform output -raw kubeconfig_command)     # point kubectl at the cluster
```

This creates the VPC, EKS cluster + node group, ECR repos, the AWS Load Balancer
Controller, metrics-server, IRSA roles, and the **GitHub OIDC deploy role**.

## 2. ACM certificate + DNS

The ALB terminates TLS with an ACM certificate in the **same region** as the cluster:

```bash
aws acm request-certificate --domain-name app.example.com \
  --validation-method DNS --region <region>
# create the CNAME it asks for, wait for status ISSUED, then note the certificate ARN
```

After the first deploy, read the ALB hostname and point DNS at it:

```bash
kubectl -n aisat get ingress aisat        # ADDRESS column = ALB DNS name
# create a CNAME (or Route 53 ALIAS/A) for app.example.com -> that ALB hostname
```

## 3. GitHub configuration

**Settings → Secrets and variables → Actions → Variables** (from `terraform output`):

| Variable              | Source (`terraform output`)         | Used for                         |
| --------------------- | ----------------------------------- | -------------------------------- |
| `AWS_REGION`          | `region`                            | AWS region for OIDC + kubeconfig |
| `AWS_DEPLOY_ROLE_ARN` | `github_deploy_role_arn`            | role the workflow assumes (OIDC) |
| `EKS_CLUSTER_NAME`    | `cluster_name`                      | `aws eks update-kubeconfig`      |
| `ECR_REGISTRY`        | `ecr_registry`                      | image registry host              |
| `ACM_CERTIFICATE_ARN` | ACM (step 2)                        | ALB TLS certificate              |
| `PRODUCTION_HOST`     | your domain (shared with DO path)   | Ingress host + environment URL   |
| `EKS_NAMESPACE`       | optional; defaults to `aisat`       | release namespace                |

`terraform output -json github_actions_config_hint` prints the first four.

**Secrets:** reuse the existing `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` from the
DO path. No AWS keys are needed — deploys use OIDC.

**Settings → Environments → `production-eks`:** add **Required reviewers** — this is
the approval gate for EKS deploys (separate from the DO `production` environment).

## 4. Application secrets

The production overlay ([helm/aisat/values-production.yaml](./helm/aisat/values-production.yaml))
pulls secrets from **AWS Secrets Manager** via the **External Secrets Operator (ESO)**.
Set this up once before the first deploy:

```bash
# a) store the app secret (keys mirror deploy/.env.production — see values.yaml `secrets.data`)
aws secretsmanager create-secret --name aisat/production --region <region> \
  --secret-string '{"POSTGRES_PASSWORD":"...","DATABASE_URL":"postgres://...","S3_ACCESS_KEY":"...","S3_SECRET_KEY":"...","LLM_GATEWAY_MASTER_KEY":"sk-...","JWT_SECRET":"...","OPENAI_API_KEY":"...","ANTHROPIC_API_KEY":"..."}'

# b) install ESO, annotating its ServiceAccount with the IRSA role Terraform created
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --set installCRDs=true \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$(terraform -chdir=deploy/eks/terraform output -raw external_secrets_role_arn)

# c) create the ClusterSecretStore the chart references (secretStoreRef: aws-secretsmanager)
kubectl apply -f - <<'YAML'
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secretsmanager
spec:
  provider:
    aws:
      service: SecretsManager
      region: <region>
YAML
```

> **Quick alternative (not for real prod):** skip ESO and create the Secret directly,
> then deploy with `--set secrets.existingSecret=aisat-secrets --set externalSecrets.enabled=false`:
>
> ```bash
> kubectl -n aisat create secret generic aisat-secrets \
>   --from-env-file=deploy/.env.production
> ```

## 5. First deploy

Trigger **Actions → CD (EKS) → Run workflow** (or push a `v*` tag). It builds +
pushes images to ECR, then waits on the `production-eks` approval. Approve it → Helm
installs the release; the migration hook runs first, then the app rolls out. You get
a Telegram message on start, success, or failure.

**Redeploy / rollback:** Actions → CD (EKS) → **Run workflow** and pass an earlier
commit SHA as `image_tag`. Helm `--atomic` also auto-rolls-back to the previous
revision if a deploy fails its health/rollout checks. Manual rollback:

```bash
helm -n aisat history aisat
helm -n aisat rollback aisat <REVISION>
```

---

## Backing services: in-cluster vs managed

By default the chart runs Postgres/Redis/NATS/Qdrant/MinIO as **in-cluster
StatefulSets** (EBS-backed) for a self-contained deploy. For production, move the
stateful stores to managed services:

1. `terraform apply` with `enable_rds_postgres = true` / `enable_elasticache_redis = true`.
2. In the Secrets Manager secret, set `DATABASE_URL` to the RDS endpoint; in the chart
   `config`, set `REDIS_URL` to the ElastiCache endpoint.
3. Disable the in-cluster ones: `--set backingStatefulSets.postgres.enabled=false`
   `--set backingStatefulSets.redis.enabled=false` (or in values-production.yaml).

RDS's master password is managed in Secrets Manager (`rds_postgres_secret_arn`) — wire
it into the app secret so `DATABASE_URL` stays in sync.

## Production hardening checklist

Per [../../.github/instructions/devops-cicd.instructions.md](../../.github/instructions/devops-cicd.instructions.md):

- [ ] **Pin actions to commit SHAs** (`cd-eks.yml`, `ci.yml`); Dependabot maintains them.
- [ ] **Pin base + service images by `@sha256`** (Dockerfiles + chart `values.yaml`); verify
      floating tags (`litellm:main-stable`, `minio`, `casdoor`).
- [ ] **Make image CVEs blocking**: set `exit-code: '1'` on the Trivy step in `cd-eks.yml`.
- [ ] **Lock the API endpoint**: set `cluster_endpoint_public_access_cidrs` to your admin/CI IPs.
- [ ] **Managed data stores** (RDS/ElastiCache) + off-cluster backups instead of EBS PVCs.
- [ ] **Secrets via ESO/Secrets Manager** (default) — never the chart-managed plaintext Secret.
- [ ] Restrict `github_deploy_ref` and add environment protection so only trusted refs deploy.
- [ ] Consider a **private/hybrid API endpoint** and network policies for pod-to-pod isolation.
