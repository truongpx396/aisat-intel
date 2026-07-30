# Optional off-box data services. Default OFF — Postgres/Redis/MinIO run in the
# droplet's compose stack. Flip these on to harden for production, then point
# .env.production at the outputs and drop those services from the compose file.

# --- Managed PostgreSQL -----------------------------------------------------
resource "digitalocean_database_cluster" "postgres" {
  count                = var.enable_managed_postgres ? 1 : 0
  name                 = "${var.project_name}-pg"
  engine               = "pg"
  version              = var.postgres_version
  size                 = var.postgres_size
  region               = var.region
  node_count           = var.postgres_node_count
  private_network_uuid = digitalocean_vpc.main.id
  tags                 = var.tags
}

resource "digitalocean_database_db" "app" {
  count      = var.enable_managed_postgres ? 1 : 0
  cluster_id = digitalocean_database_cluster.postgres[0].id
  name       = "aisat"
}

# Only the droplet may reach the cluster (private network).
resource "digitalocean_database_firewall" "postgres" {
  count      = var.enable_managed_postgres ? 1 : 0
  cluster_id = digitalocean_database_cluster.postgres[0].id
  rule {
    type  = "droplet"
    value = digitalocean_droplet.web.id
  }
}

# --- Managed Redis ----------------------------------------------------------
resource "digitalocean_database_cluster" "redis" {
  count                = var.enable_managed_redis ? 1 : 0
  name                 = "${var.project_name}-redis"
  engine               = "redis"
  version              = var.redis_version
  size                 = var.redis_size
  region               = var.region
  node_count           = 1
  private_network_uuid = digitalocean_vpc.main.id
  tags                 = var.tags
}

resource "digitalocean_database_firewall" "redis" {
  count      = var.enable_managed_redis ? 1 : 0
  cluster_id = digitalocean_database_cluster.redis[0].id
  rule {
    type  = "droplet"
    value = digitalocean_droplet.web.id
  }
}

# --- Object storage (Spaces) — future SPA CDN origin / S3 upload target -----
resource "digitalocean_spaces_bucket" "assets" {
  count  = var.enable_spaces ? 1 : 0
  name   = var.spaces_bucket_name
  region = local.spaces_region
  acl    = "private"
}
