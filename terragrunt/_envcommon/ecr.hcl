# _envcommon/ecr.hcl (Watchtower) — one repo per LGTM/Alloy service (local module).
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/ecr-repos"
}

inputs = {
  name_prefix = "watchtower-${local.env.environment}"
  services    = ["tempo", "loki", "prometheus", "grafana", "alloy"]
}
