# Optional managed data services (default OFF). When enabled, these run in the
# VPC's private subnets and only accept traffic from the EKS node security group.
# After enabling, point the Helm chart's config at the outputs (DATABASE_URL /
# REDIS_URL) and set postgres.enabled=false / redis.enabled=false in values.

# --------------------------------- RDS Postgres ----------------------------------
resource "aws_db_subnet_group" "postgres" {
  count = var.enable_rds_postgres ? 1 : 0

  name       = "${local.name}-pg"
  subnet_ids = module.vpc.private_subnets
  tags       = local.tags
}

resource "aws_security_group" "postgres" {
  count = var.enable_rds_postgres ? 1 : 0

  name        = "${local.name}-pg"
  description = "Postgres access from EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_db_instance" "postgres" {
  count = var.enable_rds_postgres ? 1 : 0

  identifier     = "${local.name}-pg"
  engine         = "postgres"
  engine_version = var.rds_postgres_version
  instance_class = var.rds_instance_class

  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_allocated_storage * 4
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.rds_db_name
  username = var.rds_username
  # Master password is generated and rotated in AWS Secrets Manager — it never
  # touches Terraform state. Read it via External Secrets (see the chart README).
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.postgres[0].name
  vpc_security_group_ids = [aws_security_group.postgres[0].id]
  multi_az               = var.rds_multi_az
  publicly_accessible    = false

  backup_retention_period   = 7
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-pg-final"

  tags = local.tags
}

# ------------------------------- ElastiCache Redis -------------------------------
resource "aws_elasticache_subnet_group" "redis" {
  count = var.enable_elasticache_redis ? 1 : 0

  name       = "${local.name}-redis"
  subnet_ids = module.vpc.private_subnets
  tags       = local.tags
}

resource "aws_security_group" "redis" {
  count = var.enable_elasticache_redis ? 1 : 0

  name        = "${local.name}-redis"
  description = "Redis access from EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_elasticache_cluster" "redis" {
  count = var.enable_elasticache_redis ? 1 : 0

  cluster_id           = "${local.name}-redis"
  engine               = "redis"
  engine_version       = var.elasticache_engine_version
  node_type            = var.elasticache_node_type
  num_cache_nodes      = 1
  port                 = 6379
  parameter_group_name = "default.redis7"

  subnet_group_name  = aws_elasticache_subnet_group.redis[0].name
  security_group_ids = [aws_security_group.redis[0].id]

  tags = local.tags
}
