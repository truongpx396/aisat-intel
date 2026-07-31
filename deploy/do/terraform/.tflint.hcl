# TFLint config for the DigitalOcean Terraform root.
# Auto-discovered by `tflint` when run from this directory (CI: the `terraform`
# job in .github/workflows/ci.yml; locally: `cd deploy/do/terraform && tflint`).
# There is no official DigitalOcean ruleset, so this uses the core terraform
# ruleset only. Run `tflint --init` once to install it.

config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
