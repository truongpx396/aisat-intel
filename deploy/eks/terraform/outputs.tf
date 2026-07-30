output "region" {
  description = "AWS region the cluster lives in (-> AWS_REGION)."
  value       = var.region
}

output "cluster_name" {
  description = "EKS cluster name (-> EKS_CLUSTER_NAME)."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_oidc_provider_arn" {
  description = "IRSA OIDC provider ARN."
  value       = module.eks.oidc_provider_arn
}

output "ecr_registry" {
  description = "ECR registry host (-> ECR_REGISTRY). Prefix for every image ref."
  value       = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

output "ecr_repository_urls" {
  description = "Full push/pull URL per app image."
  value       = { for name, r in aws_ecr_repository.app : name => r.repository_url }
}

output "github_deploy_role_arn" {
  description = "Role the CD workflow assumes via OIDC (-> AWS_DEPLOY_ROLE_ARN)."
  value       = aws_iam_role.github_deploy.arn
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "external_secrets_role_arn" {
  description = "IRSA role for the External Secrets Operator SA (annotate its ServiceAccount with this)."
  value       = var.enable_external_secrets_irsa ? module.external_secrets_irsa[0].iam_role_arn : null
}

output "rds_postgres_endpoint" {
  description = "RDS Postgres endpoint host:port (build DATABASE_URL from it)."
  value       = var.enable_rds_postgres ? aws_db_instance.postgres[0].endpoint : null
}

output "rds_postgres_secret_arn" {
  description = "Secrets Manager ARN holding the RDS master password (read via External Secrets)."
  value       = var.enable_rds_postgres ? aws_db_instance.postgres[0].master_user_secret[0].secret_arn : null
}

output "elasticache_redis_endpoint" {
  description = "ElastiCache Redis primary endpoint host (build REDIS_URL from it)."
  value       = var.enable_elasticache_redis ? aws_elasticache_cluster.redis[0].cache_nodes[0].address : null
}

# ---------------------------------------------------------------------------
# Observability + GitOps access hints
# ---------------------------------------------------------------------------
output "grafana_access_hint" {
  description = "How to reach Grafana (kube-prometheus-stack). Login: admin / grafana_admin_password."
  value = var.enable_kube_prometheus_stack ? join(" && ", [
    "kubectl -n ${var.monitoring_namespace} port-forward svc/kube-prometheus-stack-grafana 3000:80",
    "open http://localhost:3000",
  ]) : null
}

output "prometheus_access_hint" {
  description = "How to reach the Prometheus UI."
  value       = var.enable_kube_prometheus_stack ? "kubectl -n ${var.monitoring_namespace} port-forward svc/kube-prometheus-stack-prometheus 9090:9090" : null
}

output "tempo_otlp_endpoint" {
  description = "In-cluster OTLP endpoint for app traces (OTEL_EXPORTER_OTLP_ENDPOINT)."
  value       = var.enable_tempo ? "http://tempo.${var.monitoring_namespace}.svc:4318" : null
}

output "langfuse_access_hint" {
  description = "How to reach the Langfuse UI (service name may vary by chart version)."
  value       = var.enable_langfuse ? "kubectl -n ${var.langfuse_namespace} port-forward svc/langfuse-web 3000:3000" : null
}

output "argocd_access_hint" {
  description = "How to reach Argo CD and fetch the initial admin password."
  value = var.enable_argocd ? join(" && ", [
    "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo",
    "kubectl -n ${var.argocd_namespace} port-forward svc/argocd-server 8080:443",
  ]) : null
}

# Copy these onto the pipeline's GitHub Actions Variables (see deploy/eks/SETUP.md).
output "github_actions_config_hint" {
  description = "Map onto GitHub Actions Variables for .github/workflows/cd-eks.yml."
  value = {
    AWS_REGION          = var.region
    AWS_DEPLOY_ROLE_ARN = aws_iam_role.github_deploy.arn
    EKS_CLUSTER_NAME    = module.eks.cluster_name
    ECR_REGISTRY        = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  }
}
