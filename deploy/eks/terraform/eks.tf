# EKS control plane + managed node group (official module).
#
# - IRSA is enabled: the cluster gets an OIDC provider so ServiceAccounts can
#   assume IAM roles (used by the ALB controller, EBS CSI driver, and the app).
# - Access is granted via EKS *access entries* (the modern replacement for the
#   aws-auth ConfigMap): the Terraform caller becomes admin, plus any ARNs in
#   var.cluster_admin_principal_arns and the GitHub deploy role (see github-oidc.tf).
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  enable_irsa = true

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Core add-ons managed by EKS. The EBS CSI driver backs PersistentVolumes for
  # the in-cluster StatefulSets (Postgres/Qdrant/MinIO) via gp3.
  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD"
    # Pull-through access to ECR + SSM for break-glass debugging.
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }

  eks_managed_node_groups = merge(
    {
      default = {
        instance_types = var.node_instance_types
        capacity_type  = var.node_capacity_type

        min_size     = var.node_min_size
        max_size     = var.node_max_size
        desired_size = var.node_desired_size
        disk_size    = var.node_disk_size

        labels = {
          role = "app"
        }
      }
    },
    # Dedicated KVM / bare-metal pool for the microVM sandbox fleet (crawl4ai,
    # MarkItDown convert, code-gen). Firecracker needs /dev/kvm, which the default
    # nitro instances (t3.large) do NOT expose — hence a *.metal instance type.
    # Tainted so ONLY sandbox VMs land here (blast-radius + resource isolation).
    # See sandbox.tf for the full rationale and the self-host control-plane seam.
    var.sandbox_enabled ? {
      sandbox = {
        instance_types = var.sandbox_instance_types
        capacity_type  = var.sandbox_capacity_type

        min_size     = var.sandbox_min_size
        max_size     = var.sandbox_max_size
        desired_size = var.sandbox_desired_size
        disk_size    = var.sandbox_disk_size

        labels = {
          role = "sandbox"
        }
        taints = {
          sandbox = {
            key    = "sandbox"
            value  = "true"
            effect = "NO_SCHEDULE"
          }
        }
      }
    } : {},
  )

  # Access entries. enable_cluster_creator_admin_permissions grants whoever runs
  # `terraform apply`; the map adds break-glass admins + the CI deploy role.
  enable_cluster_creator_admin_permissions = true

  access_entries = merge(
    {
      github_deploy = {
        principal_arn = aws_iam_role.github_deploy.arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
    {
      for idx, arn in var.cluster_admin_principal_arns : "admin_${idx}" => {
        principal_arn = arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
  )

  tags = local.tags
}
