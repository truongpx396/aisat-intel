# Terraform — AWS EKS provisioning

Provisions the AWS infrastructure the EKS CD pipeline deploys onto. Terraform
builds the **cluster, network, registry, and IAM**; GitHub Actions builds and
ships the **app** (Helm chart) onto it.

```
Terraform  ─►  VPC · EKS (managed node group, IRSA/OIDC) · ECR repos
               AWS Load Balancer Controller · GitHub OIDC deploy role
               [optional] RDS Postgres · ElastiCache Redis
GitHub CD  ─►  build → ECR → helm upgrade → ALB Ingress   (../SETUP.md)
```

## What it creates

| Always                                                                                                                                                    | Optional (toggle)                                                                    |
| --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| VPC (public + private subnets, NAT), EKS control plane + managed node group, core add-ons (CoreDNS, kube-proxy, VPC CNI, EBS CSI), `gp3` StorageClass, IRSA/OIDC, ECR repos, AWS Load Balancer Controller, GitHub Actions OIDC deploy role | `install_alb_controller` · `enable_rds_postgres` · `enable_elasticache_redis` · `create_github_oidc_provider` · **observability**: `enable_kube_prometheus_stack` · `enable_loki` · `enable_tempo` · `enable_langfuse` · `enable_argocd` |

The observability add-ons (kube-prometheus-stack, Loki, Tempo, Langfuse) and Argo
CD install via Helm and are **on by default** — see [../SETUP.md](../SETUP.md#observability--gitops-installed-by-terraform).
Their chart versions are pinned via variables; `terraform validate` does **not**
fetch charts, so verify the pins against the upstream indexes before apply.

Managed data services are **off by default** — Postgres/Redis (and the rest of
the backing services) run in-cluster via the Helm chart. Turn RDS/ElastiCache on
to harden for production, then repoint the chart's config at the outputs and set
`postgres.enabled=false` / `redis.enabled=false`.

## Prerequisites

- Terraform ≥ 1.6 (or OpenTofu), plus the `aws`, `kubectl`, and `helm` CLIs.
- AWS credentials with permission to create VPC/EKS/IAM/ECR (admin for the first
  apply is simplest). Pass via `AWS_PROFILE` or `AWS_ACCESS_KEY_ID`/`_SECRET_ACCESS_KEY`.
- The provider blocks call `aws eks get-token`, so the `aws` CLI must be on PATH.

## Usage

```bash
cd deploy/eks/terraform
cp terraform.tfvars.example terraform.tfvars   # set region, cluster_name, github_*, ...
export AWS_PROFILE=aisat                         # or export static keys

terraform init
terraform plan
terraform apply                                  # ~15–20 min for the control plane + nodes
```

Point `kubectl` at the new cluster:

```bash
$(terraform output -raw kubeconfig_command)
kubectl get nodes
```

## Wiring outputs into the pipeline

`terraform output` feeds the GitHub config from [../SETUP.md](../SETUP.md):

| Output                   | GitHub Actions                                   |
| ------------------------ | ------------------------------------------------ |
| `region`                 | variable `AWS_REGION`                            |
| `github_deploy_role_arn` | variable `AWS_DEPLOY_ROLE_ARN`                   |
| `cluster_name`           | variable `EKS_CLUSTER_NAME`                      |
| `ecr_registry`           | variable `ECR_REGISTRY`                          |
| `rds_postgres_endpoint` / `elasticache_redis_endpoint` | chart config (when enabled) |

`terraform output -json github_actions_config_hint` prints the first four ready
to copy. No long-lived AWS keys are ever created — the workflow assumes
`github_deploy_role_arn` via OIDC.

## State

Local state by default. For team/CI use, enable the **S3 + DynamoDB** backend in
`backend.tf.example` (rename to `backend.tf`, create the bucket + lock table
first, then `terraform init -migrate-state`).

## Teardown

```bash
# Delete the app + its ALB first so the controller releases the load balancer,
# otherwise the VPC won't destroy cleanly:
helm uninstall aisat -n aisat || true
terraform destroy
```

> RDS has `deletion_protection = true` and takes a final snapshot; disable/adjust
> before destroying if you truly want it gone. ECR repos have `force_delete=false`,
> so empty them first if they still hold images.

## Notes

- VPC + EKS use the official `terraform-aws-modules` (pinned) — the community
  standard for correct, secure EKS wiring. ECR, IRSA-for-app, the GitHub OIDC
  role, and the optional data services are explicit resources.
- The GitHub OIDC provider is account-global (only one allowed). If it already
  exists, set `create_github_oidc_provider = false`.
- Validated in CI (`terraform fmt` + `validate`). Tighten provider/module pins and
  the public-endpoint CIDRs per the repo's supply-chain standard before real traffic.
