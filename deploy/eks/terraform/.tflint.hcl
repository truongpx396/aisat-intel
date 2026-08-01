# TFLint config for the AWS EKS Terraform root.
# Auto-discovered by `tflint` when run from this directory (CI: the `terraform`
# job in .github/workflows/ci.yml; locally: `cd deploy/eks/terraform && tflint`).
# Run `tflint --init` once to install the plugins below.

config {
  # Lint the whole root, not just the current file.
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# AWS ruleset: validates instance types, IAM policy docs, deprecated resources,
# etc. from static config (no credentials / no "deep check" needed).
plugin "aws" {
  enabled = true
  version = "0.35.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
