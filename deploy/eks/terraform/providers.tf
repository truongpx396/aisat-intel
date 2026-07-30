# AWS provider — credentials come from the environment (never commit them):
#   export AWS_PROFILE=...              (or)
#   export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...  AWS_SESSION_TOKEN=...
# default_tags stamp every taggable resource so cost/ownership is greppable.
provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# The kubernetes/helm providers authenticate to the cluster the EKS module
# creates. We resolve a short-lived token via the aws CLI exec plugin rather than
# baking a long-lived kubeconfig into state — the token is minted at apply time.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
