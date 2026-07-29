locals {
  app_dir       = "/opt/aisat-intel"
  spaces_region = var.spaces_region != "" ? var.spaces_region : var.region

  # cloud-init that brings a fresh droplet up ready for the CD pipeline
  # (Docker + Compose, the deploy user, and the app directory).
  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    deploy_user    = var.deploy_user
    ssh_public_key = trimspace(var.ssh_public_key)
    app_dir        = local.app_dir
  })
}
