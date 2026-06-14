# _envcommon/acm.hcl (Watchtower) — TLS cert for the Grafana hostname.
# Skip this unit + the ALB HTTPS listener if you have no domain (see README).
locals {
  account = read_terragrunt_config(find_in_parent_folders("account.hcl")).locals
  env     = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals

  fqdn = local.env.environment == "prod" ? local.account.domain_base : "${local.env.environment}.${local.account.domain_base}"
}

terraform {
  source = "tfr:///terraform-aws-modules/acm/aws//.?version=5.1.1"
}

inputs = {
  domain_name            = local.fqdn
  zone_id                = local.account.hosted_zone_id
  validation_method      = "DNS"
  create_route53_records = true
  wait_for_validation    = true
}
