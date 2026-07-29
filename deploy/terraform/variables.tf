# ---------------------------------------------------------------------------
# Credentials (pass via environment, never commit)
# ---------------------------------------------------------------------------
variable "do_token" {
  description = "DigitalOcean API token. Set via TF_VAR_do_token."
  type        = string
  sensitive   = true
}

variable "spaces_access_id" {
  description = "Spaces access key ID (only needed when enable_spaces = true)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "spaces_secret_key" {
  description = "Spaces secret key (only needed when enable_spaces = true)."
  type        = string
  default     = ""
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Placement / naming
# ---------------------------------------------------------------------------
variable "region" {
  description = "DigitalOcean region slug (e.g. sgp1, fra1, nyc3)."
  type        = string
  default     = "sgp1"
}

variable "project_name" {
  description = "DigitalOcean project to group all resources under."
  type        = string
  default     = "aisat-intel"
}

variable "environment" {
  description = "Project environment label (Development | Staging | Production)."
  type        = string
  default     = "Production"
}

variable "tags" {
  description = "Tags applied to taggable resources."
  type        = list(string)
  default     = ["aisat-intel", "prod"]
}

# ---------------------------------------------------------------------------
# Droplet
# ---------------------------------------------------------------------------
variable "droplet_name" {
  description = "Droplet hostname."
  type        = string
  default     = "aisat-intel-prod"
}

variable "droplet_size" {
  description = "Droplet size slug. s-2vcpu-4gb is a sane starting point."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "droplet_image" {
  description = "Base image slug."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "enable_droplet_backups" {
  description = "Enable DigitalOcean's automated weekly droplet backups."
  type        = bool
  default     = true
}

variable "deploy_user" {
  description = "Non-root user the CD pipeline SSHes in as (matches DROPLET_USER)."
  type        = string
  default     = "deploy"
}

# ---------------------------------------------------------------------------
# SSH / access
# ---------------------------------------------------------------------------
variable "ssh_public_key" {
  description = "Public half of the deploy key pair (the private half is the DROPLET_SSH_KEY GitHub secret)."
  type        = string
}

variable "ssh_key_name" {
  description = "Name for the uploaded SSH key in DigitalOcean."
  type        = string
  default     = "aisat-deploy"
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to reach SSH (22). Tighten to your admin IP for production."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

# ---------------------------------------------------------------------------
# DNS (optional — only if you manage the domain's nameservers at DigitalOcean)
# ---------------------------------------------------------------------------
variable "domain" {
  description = "Apex domain served by Caddy (matches PRODUCTION_HOST). Empty to skip DNS."
  type        = string
  default     = ""
}

variable "manage_dns" {
  description = "Create the DO DNS zone + A records for `domain`. Requires the domain's NS to point at DO."
  type        = bool
  default     = false
}

variable "create_www_record" {
  description = "Also create a www CNAME -> apex when managing DNS."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Optional managed data services (default: everything runs in the droplet's
# compose stack). Flip these on to move Postgres/Redis off-box; then point
# .env.production at the outputs and drop those services from the compose file.
# ---------------------------------------------------------------------------
variable "enable_managed_postgres" {
  description = "Provision a managed PostgreSQL cluster instead of the in-compose Postgres."
  type        = bool
  default     = false
}

variable "postgres_version" {
  type    = string
  default = "16"
}

variable "postgres_size" {
  type    = string
  default = "db-s-1vcpu-1gb"
}

variable "postgres_node_count" {
  type    = number
  default = 1
}

variable "enable_managed_redis" {
  description = "Provision a managed Redis (Valkey) cluster instead of the in-compose Redis."
  type        = bool
  default     = false
}

variable "redis_version" {
  type    = string
  default = "7"
}

variable "redis_size" {
  type    = string
  default = "db-s-1vcpu-1gb"
}

# ---------------------------------------------------------------------------
# Optional object storage (Spaces) — the future CDN origin for the SPA and/or
# an S3-compatible target for uploads (replaces in-compose MinIO).
# ---------------------------------------------------------------------------
variable "enable_spaces" {
  description = "Create a Spaces bucket. Requires spaces_access_id/spaces_secret_key."
  type        = bool
  default     = false
}

variable "spaces_region" {
  description = "Spaces region (must be a Spaces-enabled region). Defaults to var.region."
  type        = string
  default     = ""
}

variable "spaces_bucket_name" {
  description = "Globally-unique Spaces bucket name."
  type        = string
  default     = "aisat-intel-assets"
}

# ---------------------------------------------------------------------------
# Optional monitoring alerts
# ---------------------------------------------------------------------------
variable "enable_monitoring_alerts" {
  description = "Create CPU/memory/disk monitor alerts for the droplet."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email address that receives monitor alerts (required if alerts enabled)."
  type        = string
  default     = ""
}
