# _envcommon/dns.hcl (Watchtower) — public A/ALIAS for the Grafana hostname →
# the ALB. Latency-routed in prod (multi-region). Skip if no domain.
locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
  env     = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
  region  = read_terragrunt_config(find_in_parent_folders("region.hcl")).locals

  fqdn = local.env.environment == "prod" ? local.account.domain_base : "${local.env.environment}.${local.account.domain_base}"
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/route53-alias"
}

dependency "alb" {
  config_path = "../alb"
  mock_outputs = {
    dns_name = "mock-alb-123.us-west-2.elb.amazonaws.com"
    zone_id  = "Z0MOCKALBZONE"
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}

inputs = {
  zone_id      = local.account.hosted_zone_id
  name         = local.fqdn
  alb_dns_name = dependency.alb.outputs.dns_name
  alb_zone_id  = dependency.alb.outputs.zone_id

  enable_latency_routing = local.env.environment == "prod"
  region                 = local.region.aws_region
}
