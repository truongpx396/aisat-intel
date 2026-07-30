# DigitalOcean provider.
# - do_token: pass via env `export TF_VAR_do_token=...` (never commit it).
# - spaces_*: only needed when enable_spaces = true (Spaces API keys, distinct
#   from the API token). Left empty otherwise.
provider "digitalocean" {
  token             = var.do_token
  spaces_access_id  = var.spaces_access_id
  spaces_secret_key = var.spaces_secret_key
}
