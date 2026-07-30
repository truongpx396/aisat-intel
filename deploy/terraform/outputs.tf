output "droplet_id" {
  description = "Droplet ID."
  value       = digitalocean_droplet.web.id
}

output "droplet_ipv4" {
  description = "Ephemeral droplet IP (prefer the reserved IP for DNS/secrets)."
  value       = digitalocean_droplet.web.ipv4_address
}

output "reserved_ipv4" {
  description = "Stable public IP — set as the DROPLET_HOST GitHub secret (or use the domain)."
  value       = digitalocean_reserved_ip.web.ip_address
}

output "app_url" {
  description = "Where the app will be reachable once DNS + deploy are done."
  value       = var.domain != "" ? "https://${var.domain}" : "https://${digitalocean_reserved_ip.web.ip_address}"
}

output "domain_nameservers" {
  description = "Delegate your registrar's NS to these when manage_dns = true."
  value       = var.manage_dns ? ["ns1.digitalocean.com", "ns2.digitalocean.com", "ns3.digitalocean.com"] : []
}

output "postgres_uri" {
  description = "Managed Postgres private connection URI (-> DATABASE_URL)."
  value       = var.enable_managed_postgres ? digitalocean_database_cluster.postgres[0].private_uri : null
  sensitive   = true
}

output "redis_uri" {
  description = "Managed Redis private connection URI (-> REDIS_URL)."
  value       = var.enable_managed_redis ? digitalocean_database_cluster.redis[0].private_uri : null
  sensitive   = true
}

output "spaces_endpoint" {
  description = "Spaces S3 endpoint (-> S3_ENDPOINT)."
  value       = var.enable_spaces ? "https://${local.spaces_region}.digitaloceanspaces.com" : null
}

output "spaces_bucket" {
  description = "Spaces bucket name (-> S3_BUCKET)."
  value       = var.enable_spaces ? digitalocean_spaces_bucket.assets[0].name : null
}

output "github_secrets_hint" {
  description = "Map these onto the pipeline's GitHub secrets/variables (see deploy/SETUP.md)."
  value = {
    DROPLET_HOST    = digitalocean_reserved_ip.web.ip_address # secret
    DROPLET_USER    = var.deploy_user                         # secret
    PRODUCTION_HOST = var.domain                              # variable
  }
}
