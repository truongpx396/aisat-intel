# The deploy key pair used by the CD pipeline. The PUBLIC half is uploaded here;
# the PRIVATE half is the GitHub secret DROPLET_SSH_KEY.
resource "digitalocean_ssh_key" "deploy" {
  name       = var.ssh_key_name
  public_key = trimspace(var.ssh_public_key)
}

resource "digitalocean_droplet" "web" {
  name       = var.droplet_name
  image      = var.droplet_image
  region     = var.region
  size       = var.droplet_size
  vpc_uuid   = digitalocean_vpc.main.id
  ssh_keys   = [digitalocean_ssh_key.deploy.fingerprint]
  user_data  = local.cloud_init
  backups    = var.enable_droplet_backups
  monitoring = true
  ipv6       = true
  tags       = var.tags

  lifecycle {
    # Changing user_data would otherwise force-replace the droplet; the bootstrap
    # only matters on first boot, so ignore drift there and keep the box stable.
    ignore_changes = [user_data]
  }
}
