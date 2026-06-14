# _envcommon/s3.hcl (Watchtower) — Loki + Tempo object-storage backends.
locals {
  region = read_terragrunt_config(find_in_parent_folders("region.hcl")).locals
  env    = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/s3-buckets"
}

inputs = {
  # Bucket names are global; env+region keep them unique.
  name_prefix    = "watchtower-${local.env.environment}-${local.region.aws_region}"
  buckets        = ["loki", "tempo"]
  retention_days = local.env.environment == "prod" ? 30 : 7
}
