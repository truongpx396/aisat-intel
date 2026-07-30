# DNS is optional (manage_dns). It treats `domain` as a zone hosted at
# DigitalOcean — delegate the domain's nameservers to DO first (see outputs).
# For a subdomain served by Caddy, either host the parent zone here or leave
# manage_dns = false and point an A record at the reserved IP yourself.
resource "digitalocean_domain" "this" {
  count = var.manage_dns && var.domain != "" ? 1 : 0
  name  = var.domain
}

resource "digitalocean_record" "apex" {
  count  = var.manage_dns && var.domain != "" ? 1 : 0
  domain = digitalocean_domain.this[0].id
  type   = "A"
  name   = "@"
  value  = digitalocean_reserved_ip.web.ip_address
  ttl    = 300
}

resource "digitalocean_record" "www" {
  count  = var.manage_dns && var.domain != "" && var.create_www_record ? 1 : 0
  domain = digitalocean_domain.this[0].id
  type   = "CNAME"
  name   = "www"
  value  = "@"
  ttl    = 300
}
