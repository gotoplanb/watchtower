# _envcommon/security-groups.hcl (Watchtower) — local module; ALB + app SGs,
# with OTLP ingress allowed from the peered Conduct CIDRs (account.hcl).
locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
  env     = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/security-groups"
}

dependency "vpc" {
  config_path                             = "../vpc"
  mock_outputs                            = { vpc_id = "vpc-00000000000000000" }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}

inputs = {
  name_prefix        = "watchtower-${local.env.environment}"
  vpc_id             = dependency.vpc.outputs.vpc_id
  otlp_allowed_cidrs = local.account.otlp_allowed_cidrs
}
