# Group everything under one DigitalOcean project for tidy billing/visibility.
resource "digitalocean_project" "this" {
  name        = var.project_name
  description = "AISAT-INTEL production infrastructure (managed by Terraform)."
  purpose     = "Web Application"
  environment = var.environment

  resources = concat(
    [
      digitalocean_droplet.web.urn,
      digitalocean_reserved_ip.web.urn,
    ],
    digitalocean_domain.this[*].urn,
    digitalocean_database_cluster.postgres[*].urn,
    digitalocean_database_cluster.redis[*].urn,
    digitalocean_spaces_bucket.assets[*].urn,
  )
}
