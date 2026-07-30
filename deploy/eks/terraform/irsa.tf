# IRSA (IAM Roles for Service Accounts) — maps a Kubernetes ServiceAccount to an
# IAM role via the cluster's OIDC provider, so in-cluster controllers get exactly
# the AWS permissions they need without node-wide credentials.

# EBS CSI driver — provisions gp3 volumes for the StatefulSet PVCs.
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name             = "${local.name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

# AWS Load Balancer Controller — reconciles the ALB behind the chart's Ingress.
module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                              = "${local.name}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.tags
}

# External Secrets Operator — reads the app secret from AWS Secrets Manager.
module "external_secrets_irsa" {
  count   = var.enable_external_secrets_irsa ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                             = "${local.name}-external-secrets"
  attach_external_secrets_policy        = true
  external_secrets_secrets_manager_arns = [var.secrets_manager_arn_pattern]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${var.external_secrets_namespace}:${var.external_secrets_service_account}"]
    }
  }

  tags = local.tags
}
