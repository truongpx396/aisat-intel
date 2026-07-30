# GitHub Actions OIDC — lets the CD workflow assume a scoped AWS role at run time
# with NO long-lived keys stored as GitHub secrets. The trust policy pins the
# provider's audience + the repo/ref 'sub' claim, so only workflows from this
# repo on the trusted ref can assume the role.

# The account may already have the GitHub OIDC provider (only one is allowed per
# account). Create it here, or set create_github_oidc_provider = false and let the
# data source below find the existing one.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = local.tags
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn

  cluster_arn = "arn:aws:eks:${var.region}:${local.account_id}:cluster/${var.cluster_name}"
}

data "aws_iam_policy_document" "github_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scope to this repo + the trusted ref (branch or tag pattern).
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_owner}/${var.github_repo}:ref:${var.github_deploy_ref}"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name                 = "${local.name}-github-deploy"
  description          = "Assumed by GitHub Actions (OIDC) to push to ECR and deploy to EKS."
  assume_role_policy   = data.aws_iam_policy_document.github_deploy_trust.json
  max_session_duration = 3600

  tags = local.tags
}

# ECR: auth token (account-wide) + push/pull on the app repos only.
data "aws_iam_policy_document" "github_deploy_ecr" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }

  # Reach the cluster to fetch a kubeconfig token (`aws eks update-kubeconfig`).
  statement {
    sid       = "EksDescribe"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [local.cluster_arn]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "ecr-and-eks"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy_ecr.json
}
