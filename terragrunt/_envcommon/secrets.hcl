# _envcommon/secrets.hcl (Watchtower) — Secrets Manager container for the
# Grafana admin password. Value set out-of-band (see README). Reuses the same
# app-secrets local module as Conduct.
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/app-secrets"
}

inputs = {
  name_prefix  = "watchtower/${local.env.environment}"
  secret_names = ["grafana-admin-password"]
}
