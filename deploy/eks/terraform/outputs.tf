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
