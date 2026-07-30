# Terraform — DigitalOcean provisioning

Provisions the infrastructure the CD pipeline deploys onto. Terraform builds the
**box and network**; GitHub Actions builds and ships the **app** onto it.

```
Terraform  ─►  VPC · droplet (cloud-init: Docker + deploy user) · reserved IP
               firewall · DNS · [managed PG/Redis] · [Spaces] · [alerts] · project
GitHub CD  ─►  scp deploy/ ─► droplet ─► compose pull/migrate/up   (deploy/SETUP.md)
```

## What it creates

| Always | Optional (toggle)                                            |
| ------ | ------------------------------------------------------------ |
| VPC, droplet (Ubuntu + Docker via cloud-init), reserved IP, cloud firewall (22/80/443), uploaded SSH key, DO project | `manage_dns` DNS zone + A/CNAME · `enable_managed_postgres` · `enable_managed_redis` · `enable_spaces` bucket · `enable_monitoring_alerts` |

Managed data services are **off by default** — Postgres/Redis/MinIO run in the
droplet's compose stack. Turn them on to harden for production, then repoint
`.env.production` at the outputs and remove those services from the compose file.

## Prerequisites

- Terraform ≥ 1.6 (or OpenTofu).
- A DigitalOcean API token (read/write).
- The deploy SSH **public** key (the private half becomes the `DROPLET_SSH_KEY`
  GitHub secret — same key the CD pipeline uses).

## Usage

```bash
cd deploy/terraform
cp terraform.tfvars.example terraform.tfvars     # fill in ssh_public_key, domain, ...
export TF_VAR_do_token=dop_v1_xxxxxxxx           # never put the token in a file
# If enabling Spaces, also:
#   export TF_VAR_spaces_access_id=...  TF_VAR_spaces_secret_key=...

terraform init
terraform plan
terraform apply
```

After `apply`, wait for first-boot bootstrap to finish before the first deploy:

```bash
ssh deploy@$(terraform output -raw reserved_ipv4) 'cloud-init status --wait'
```

## Wiring outputs into the pipeline

`terraform output` feeds the GitHub config from [../SETUP.md](../SETUP.md):

| Output          | GitHub                          |
| --------------- | ------------------------------- |
| `reserved_ipv4` | secret `DROPLET_HOST`           |
| `deploy_user` (var) | secret `DROPLET_USER`       |
| `domain` (var)  | variable `PRODUCTION_HOST`      |
| `postgres_uri` / `redis_uri` / `spaces_*` | corresponding keys in `.env.production` (when enabled) |

`terraform output -json github_secrets_hint` prints the first three ready to copy.
Then create `/opt/aisat-intel/deploy/.env.production` on the droplet (secrets —
never in Terraform state) as described in SETUP.md, and trigger a deploy.

## State

Local state by default. For team/CI use, enable the S3-compatible **Spaces**
backend in `backend.tf.example` (rename to `backend.tf`, create the state bucket
first, then `terraform init -migrate-state`). State contains secrets — keep the
backend private and never commit `*.tfstate`.

## Teardown

```bash
terraform destroy
```

> This deletes the droplet and its volumes. Back up `pgdata`/`qdrantdata`/uploads
> first, or use managed services / Spaces so data outlives the droplet.

## Notes

- `user_data` (cloud-init) changes are ignored after creation (they only apply on
  first boot) so routine edits don't force-replace a running droplet.
- Actions/base images and this config are validated in CI (`terraform fmt` +
  `validate`); provider/base pins should be tightened per the repo's supply-chain
  standard before production.
