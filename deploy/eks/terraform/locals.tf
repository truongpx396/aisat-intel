data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  name = var.cluster_name

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Carve the VPC CIDR into private + public /20s, one pair per AZ.
  #   private: 10.42.0.0/20, 10.42.16.0/20, ...   (nodes, pods, RDS/ElastiCache)
  #   public : 10.42.128.0/20, 10.42.144.0/20, ... (NAT gateways, public ALBs)
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  account_id = data.aws_caller_identity.current.account_id

  tags = merge(
    {
      Project     = "aisat-intel"
      Environment = var.environment
      ManagedBy   = "terraform"
      Cluster     = var.cluster_name
    },
    var.tags,
  )
}
