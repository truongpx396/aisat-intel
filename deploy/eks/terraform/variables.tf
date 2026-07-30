# ---------------------------------------------------------------------------
# Placement / naming
# ---------------------------------------------------------------------------
variable "region" {
  description = "AWS region (e.g. ap-southeast-1, eu-central-1, us-east-1)."
  type        = string
  default     = "ap-southeast-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Used as the resource name prefix everywhere."
  type        = string
  default     = "aisat-intel-prod"
}

variable "environment" {
  description = "Environment label (development | staging | production)."
  type        = string
  default     = "production"
}

variable "tags" {
  description = "Extra tags merged onto every taggable resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread subnets across (>= 2 for HA)."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4 (EKS control plane requires subnets in >= 2 AZs)."
  }
}

variable "single_nat_gateway" {
  description = "One NAT gateway shared by all private subnets (cheaper) vs one per AZ (HA)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# EKS control plane + node group
# ---------------------------------------------------------------------------
variable "kubernetes_version" {
  description = "EKS control-plane Kubernetes version."
  type        = string
  default     = "1.30"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Tighten to your admin/CI egress IPs for production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND (stable) or SPOT (cheaper, interruptible)."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_desired_size" {
  type        = number
  description = "Desired managed node count."
  default     = 3
}

variable "node_min_size" {
  type        = number
  description = "Minimum managed node count."
  default     = 2
}

variable "node_max_size" {
  type        = number
  description = "Maximum managed node count (upper bound for scale-out)."
  default     = 6
}

variable "node_disk_size" {
  type        = number
  description = "Root EBS volume size (GiB) per node."
  default     = 50
}

# The IAM principals (role/user ARNs) granted cluster-admin via EKS access
# entries — e.g. your SSO admin role. The GitHub deploy role is added
# automatically (see github-oidc.tf), so it does NOT need to be listed here.
variable "cluster_admin_principal_arns" {
  description = "Extra IAM role/user ARNs to grant cluster-admin (EKS access entries)."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Container registry (ECR) — one private repo per app image.
# ---------------------------------------------------------------------------
variable "ecr_repositories" {
  description = "App image names to create ECR repos for. Match the CD image naming (IMAGE_PREFIX-<component>)."
  type        = list(string)
  default = [
    "aisat-backend-go",
    "aisat-backend-python",
    "aisat-crawl",
    "aisat-frontend",
  ]
}

variable "ecr_image_tag_mutability" {
  description = "IMMUTABLE (tags can't be overwritten — recommended) or MUTABLE."
  type        = string
  default     = "IMMUTABLE"
}

variable "ecr_keep_last_images" {
  description = "Lifecycle policy: number of most-recent images to retain per repo."
  type        = number
  default     = 20
}

# ---------------------------------------------------------------------------
# Ingress / TLS
# ---------------------------------------------------------------------------
variable "install_alb_controller" {
  description = "Install the AWS Load Balancer Controller (required for the ALB Ingress in the Helm chart)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC deploy role — lets the CD workflow push to ECR and reach
# the cluster WITHOUT any long-lived AWS keys stored as GitHub secrets.
# ---------------------------------------------------------------------------
variable "github_owner" {
  description = "GitHub org/user that owns the repo (the 'sub' claim's owner)."
  type        = string
  default     = "truongpx396"
}

variable "github_repo" {
  description = "Repository name (without owner)."
  type        = string
  default     = "aisat-intel"
}

variable "github_deploy_ref" {
  description = "git ref the deploy role trusts (e.g. refs/heads/main, or 'ref:refs/tags/v*'). Scopes which branch/tag can assume the role."
  type        = string
  default     = "refs/heads/main"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if token.actions.githubusercontent.com already exists in the account."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Optional managed data services. Default OFF — Postgres/Redis run in-cluster
# via the Helm chart's StatefulSets. Flip on to move them to RDS/ElastiCache,
# then point the chart's config at the outputs and disable the StatefulSets.
# ---------------------------------------------------------------------------
variable "enable_rds_postgres" {
  description = "Provision an RDS PostgreSQL instance instead of the in-cluster Postgres."
  type        = bool
  default     = false
}

variable "rds_postgres_version" {
  type    = string
  default = "16"
}

variable "rds_instance_class" {
  type    = string
  default = "db.t3.medium"
}

variable "rds_allocated_storage" {
  type    = number
  default = 20
}

variable "rds_multi_az" {
  type    = bool
  default = false
}

variable "rds_db_name" {
  type    = string
  default = "aisat"
}

variable "rds_username" {
  type    = string
  default = "aisat"
}

variable "enable_elasticache_redis" {
  description = "Provision an ElastiCache (Redis) node instead of the in-cluster Redis."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# External Secrets Operator IRSA — lets ESO read the app secret from AWS Secrets
# Manager (the Helm chart's production secret path). The operator itself is
# installed out of band (see deploy/eks/SETUP.md); this only mints its IAM role.
# ---------------------------------------------------------------------------
variable "enable_external_secrets_irsa" {
  description = "Create an IRSA role for the External Secrets Operator to read AWS Secrets Manager."
  type        = bool
  default     = true
}

variable "external_secrets_namespace" {
  type    = string
  default = "external-secrets"
}

variable "external_secrets_service_account" {
  type    = string
  default = "external-secrets"
}

variable "secrets_manager_arn_pattern" {
  description = "ARN pattern the ESO role may read. Scope this to your app's secrets."
  type        = string
  default     = "arn:aws:secretsmanager:*:*:secret:aisat/*"
}

variable "elasticache_node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "elasticache_engine_version" {
  type    = string
  default = "7.1"
}

# ---------------------------------------------------------------------------
# Observability add-ons (Helm releases, installed after the cluster exists):
#   kube-prometheus-stack (Prometheus/Alertmanager/Grafana/exporters), Loki, Tempo.
#
# NOTE: chart versions are pinned to sane defaults but MUST be verified against
# the upstream chart index — `terraform validate` does NOT fetch charts, so a
# stale pin only surfaces at apply. Dependabot maintains them once merged.
# ---------------------------------------------------------------------------
variable "monitoring_namespace" {
  description = "Namespace for kube-prometheus-stack, Loki, and Tempo."
  type        = string
  default     = "monitoring"
}

variable "monitoring_storage_class" {
  description = "StorageClass for monitoring/Langfuse PVCs (gp3 is created in storage.tf)."
  type        = string
  default     = "gp3"
}

variable "enable_kube_prometheus_stack" {
  description = "Install kube-prometheus-stack (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics)."
  type        = bool
  default     = true
}

variable "kube_prometheus_stack_version" {
  description = "kube-prometheus-stack chart version (verify against the prometheus-community index)."
  type        = string
  default     = "65.5.1"
}

variable "grafana_admin_password" {
  description = "Grafana admin password (injected via set_sensitive). Override via TF_VAR_grafana_admin_password."
  type        = string
  default     = "change-me-strong"
  sensitive   = true
}

variable "enable_loki" {
  description = "Install Grafana Loki (SingleBinary, filesystem)."
  type        = bool
  default     = true
}

variable "loki_version" {
  description = "grafana/loki chart version (verify against the grafana helm index)."
  type        = string
  default     = "6.18.0"
}

variable "enable_tempo" {
  description = "Install Grafana Tempo (single binary, OTLP receivers)."
  type        = bool
  default     = true
}

variable "tempo_version" {
  description = "grafana/tempo chart version (verify against the grafana helm index)."
  type        = string
  default     = "1.10.3"
}

# ---------------------------------------------------------------------------
# Langfuse (v2) — LLM tracing/eval via the langfuse-k8s chart + bundled Postgres.
# ---------------------------------------------------------------------------
variable "enable_langfuse" {
  description = "Install Langfuse (v2) with its bundled Postgres."
  type        = bool
  default     = true
}

variable "langfuse_version" {
  description = "langfuse-k8s chart version (verify against the langfuse helm index)."
  type        = string
  default     = "0.14.0"
}

variable "langfuse_namespace" {
  description = "Namespace for Langfuse."
  type        = string
  default     = "langfuse"
}

variable "langfuse_nextauth_secret" {
  description = "Langfuse NEXTAUTH_SECRET (openssl rand -hex 32). Set via TF_VAR_langfuse_nextauth_secret."
  type        = string
  default     = "change-me-strong"
  sensitive   = true
}

variable "langfuse_salt" {
  description = "Langfuse SALT (openssl rand -hex 32). Set via TF_VAR_langfuse_salt."
  type        = string
  default     = "change-me-strong"
  sensitive   = true
}

variable "langfuse_postgres_password" {
  description = "Password for Langfuse's bundled Postgres. Set via TF_VAR_langfuse_postgres_password."
  type        = string
  default     = "change-me-strong"
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Argo CD — GitOps controller (bootstrap install). Manage the stack from Git via
# the app-of-apps in deploy/eks/argocd/ (then disable the TF-managed helm
# releases above to avoid double-management).
# ---------------------------------------------------------------------------
variable "enable_argocd" {
  description = "Install Argo CD (GitOps controller)."
  type        = bool
  default     = true
}

variable "argocd_version" {
  description = "argo/argo-cd chart version (verify against the argo helm index)."
  type        = string
  default     = "7.7.5"
}

variable "argocd_namespace" {
  description = "Namespace for Argo CD."
  type        = string
  default     = "argocd"
}

variable "argocd_domain" {
  description = "Hostname Argo CD advertises (used by the UI/CLI). Front with an Ingress or port-forward."
  type        = string
  default     = "argocd.example.com"
}
