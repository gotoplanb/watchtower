# _envcommon/ssm.hcl (Watchtower) — publish the OTLP endpoint (Alloy's internal
# NLB) + Grafana URL to SSM so Conduct can discover them. The cross-stack
# handshake; see Conduct's README §8.
locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
  env     = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
  region  = read_terragrunt_config(find_in_parent_folders("region.hcl")).locals

  fqdn = local.env.environment == "prod" ? local.account.domain_base : "${local.env.environment}.${local.account.domain_base}"
  grafana_url = (
    local.env.grafana_url_override != "" ? local.env.grafana_url_override :
    (local.account.domain_base != "" ? "https://${local.fqdn}" : "")
  )
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/ssm-params"
}

dependency "nlb" {
  config_path                             = "../nlb"
  mock_outputs                            = { dns_name = "wt-otlp-mock.elb.us-west-2.amazonaws.com" }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}

inputs = {
  env           = local.env.environment
  region        = local.region.aws_region
  otlp_endpoint = "http://${dependency.nlb.outputs.dns_name}:4317"
  grafana_url   = local.grafana_url
}
