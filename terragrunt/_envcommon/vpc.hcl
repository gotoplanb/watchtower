# _envcommon/vpc.hcl (Watchtower) — same shape as Conduct's VPC.
locals {
  region = read_terragrunt_config(find_in_parent_folders("region.hcl")).locals
  env    = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "tfr:///terraform-aws-modules/vpc/aws//.?version=5.13.0"
}

inputs = {
  name = "watchtower-${local.env.environment}-${local.region.aws_region}"
  cidr = local.region.vpc_cidr
  azs  = local.region.azs

  private_subnets = [for i, az in local.region.azs : cidrsubnet(local.region.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.region.azs : cidrsubnet(local.region.vpc_cidr, 8, i + 48)]

  enable_nat_gateway     = true
  single_nat_gateway     = local.env.environment != "prod"
  one_nat_gateway_per_az = local.env.environment == "prod"

  enable_dns_hostnames = true
  enable_dns_support   = true
}
