# ============================================================================
# Root Terragrunt configuration (Watchtower)
# ============================================================================
# Identical in spirit to Conduct's root.hcl — see conduct/terragrunt/README.md
# §1 for the full explanation of the include/hierarchy model. Every unit pulls
# this in with: include "root" { path = find_in_parent_folders("root.hcl") }
# It centralizes remote state, the AWS provider, and common tags; everything
# environment/region-specific is read from account.hcl / env.hcl / region.hcl.

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  env_vars     = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  account_id  = local.account_vars.locals.account_id
  aws_region  = local.region_vars.locals.aws_region
  environment = local.env_vars.locals.environment

  state_bucket = local.account_vars.locals.state_bucket
  state_region = local.account_vars.locals.state_region
  lock_table   = local.account_vars.locals.lock_table

  common_tags = {
    Project     = "watchtower"
    Environment = local.environment
    Region      = local.aws_region
    ManagedBy   = "terragrunt"
  }
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = local.state_bucket
    key            = "${path_relative_to_include()}/terraform.tfstate"
    region         = local.state_region
    encrypt        = true
    dynamodb_table = local.lock_table
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region              = "${local.aws_region}"
  allowed_account_ids = ["${local.account_id}"]

  default_tags {
    tags = ${jsonencode(local.common_tags)}
  }
}
EOF
}

inputs = merge(
  local.account_vars.locals,
  local.env_vars.locals,
  local.region_vars.locals,
  {
    common_tags = local.common_tags
  },
)
