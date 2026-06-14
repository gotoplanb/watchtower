# _envcommon/ecs-cluster.hcl (Watchtower) — Fargate cluster + Service Connect
# namespace (local wrapper module).
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${dirname(find_in_parent_folders("root.hcl"))}/modules/ecs-cluster"
}

inputs = {
  cluster_name   = "watchtower-${local.env.environment}"
  namespace_name = "watchtower-${local.env.environment}"
}
