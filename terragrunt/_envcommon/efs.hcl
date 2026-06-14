# _envcommon/efs.hcl (Watchtower) — persistent storage for the two STATEFUL
# single-task services: Prometheus (TSDB at /prometheus) and Grafana (its
# SQLite DB + dashboards at /var/lib/grafana). Loki/Tempo don't use EFS — they
# use S3. Two access points pin each mount to the right path + posix uid
# (Prometheus runs as 65534/nobody; Grafana as 472).
locals {
  region = read_terragrunt_config(find_in_parent_folders("region.hcl")).locals
  env    = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "tfr:///terraform-aws-modules/efs/aws//.?version=1.6.5"
}

dependency "vpc" {
  config_path                             = "../vpc"
  mock_outputs                            = { private_subnets = ["subnet-aaa", "subnet-bbb", "subnet-ccc"] }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}
dependency "sg" {
  config_path                             = "../security-groups"
  mock_outputs                            = { app_sg_id = "sg-app0000" }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}

inputs = {
  name      = "watchtower-${local.env.environment}"
  encrypted = true

  mount_targets = {
    for i, subnet in dependency.vpc.outputs.private_subnets :
    local.region.azs[i] => { subnet_id = subnet }
  }
  # EFS is reached by the same app SG the tasks run in (NFS 2049 is allowed
  # intra-SG by the security-groups module's self rule).
  security_group_ids    = [dependency.sg.outputs.app_sg_id]
  create_security_group = false

  access_points = {
    prometheus = {
      posix_user = { uid = 65534, gid = 65534 }
      root_directory = {
        path          = "/prometheus"
        creation_info = { owner_uid = 65534, owner_gid = 65534, permissions = "0755" }
      }
    }
    grafana = {
      posix_user = { uid = 472, gid = 472 }
      root_directory = {
        path          = "/var/lib/grafana"
        creation_info = { owner_uid = 472, owner_gid = 472, permissions = "0755" }
      }
    }
  }
}
