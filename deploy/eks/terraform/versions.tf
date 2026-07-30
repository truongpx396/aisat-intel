terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    # Helm + kubernetes are used to install the AWS Load Balancer Controller
    # (and, optionally, External Secrets) onto the cluster right after it exists.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Remote state (recommended for team/CI use) lives on AWS S3 with a DynamoDB
  # lock table. See backend.tf.example to enable it — kept optional so
  # `terraform init` works out of the box with local state.
}
