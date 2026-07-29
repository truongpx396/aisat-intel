terraform {
  required_version = ">= 1.6"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.43"
    }
  }

  # Remote state (recommended for team/CI use) lives on DigitalOcean Spaces,
  # which is S3-compatible. See backend.tf.example to enable it — kept optional
  # so `terraform init` works out of the box with local state.
}
