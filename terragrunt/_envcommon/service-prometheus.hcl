# _envcommon/service-prometheus.hcl — Prometheus (metrics) on Fargate.
# TSDB persists on EFS (/prometheus). Advertises prometheus:9090. The baked
# config enables the remote-write receiver (Alloy pushes metrics in).
locals {
  env    = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
  region = read_terragrunt_config(find_in_parent_folders("region.hcl")).locals
}

terraform {
  source = "tfr:///terraform-aws-modules/ecs/aws//modules/service?version=5.12.0"
}

dependency "cluster" {
  config_path                             = "../ecs-cluster"
  mock_outputs                            = { cluster_arn = "arn:aws:ecs:us-west-2:111122223333:cluster/mock", namespace_arn = "arn:aws:servicediscovery:us-west-2:111122223333:namespace/ns-mock" }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}
dependency "vpc" {
  config_path                             = "../vpc"
  mock_outputs                            = { private_subnets = ["subnet-a", "subnet-b", "subnet-c"] }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}
dependency "sg" {
  config_path                             = "../security-groups"
  mock_outputs                            = { app_sg_id = "sg-app0000" }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}
dependency "ecr" {
  config_path                             = "../ecr"
  mock_outputs                            = { repository_urls = { prometheus = "111122223333.dkr.ecr.us-west-2.amazonaws.com/wt-prometheus" } }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}
dependency "efs" {
  config_path = "../efs"
  mock_outputs = {
    id            = "fs-00000000"
    arn           = "arn:aws:elasticfilesystem:us-west-2:111122223333:file-system/fs-00000000"
    access_points = { prometheus = { id = "fsap-prom0000" }, grafana = { id = "fsap-graf0000" } }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}

inputs = {
  name          = "watchtower-${local.env.environment}-prometheus"
  cluster_arn   = dependency.cluster.outputs.cluster_arn
  cpu           = local.env.sizes.prometheus.cpu
  memory        = local.env.sizes.prometheus.memory
  desired_count = local.env.desired_count

  runtime_platform = { cpu_architecture = "ARM64", operating_system_family = "LINUX" }

  container_definitions = {
    prometheus = {
      essential     = true
      image         = "${dependency.ecr.outputs.repository_urls["prometheus"]}:${local.env.image_tag}"
      port_mappings = [{ name = "prometheus", containerPort = 9090, protocol = "tcp" }]
      # Baked config enables --web.enable-remote-write-receiver; tsdb path under
      # the EFS mount.
      mount_points             = [{ sourceVolume = "tsdb", containerPath = "/prometheus", readOnly = false }]
      readonly_root_filesystem = false
    }
  }

  volume = {
    tsdb = {
      efs_volume_configuration = {
        file_system_id     = dependency.efs.outputs.id
        transit_encryption = "ENABLED"
        authorization_config = {
          access_point_id = dependency.efs.outputs.access_points["prometheus"].id
          iam             = "ENABLED"
        }
      }
    }
  }

  subnet_ids            = dependency.vpc.outputs.private_subnets
  security_group_ids    = [dependency.sg.outputs.app_sg_id]
  create_security_group = false
  assign_public_ip      = false

  service_connect_configuration = {
    enabled   = true
    namespace = dependency.cluster.outputs.namespace_arn
    service = [{
      client_alias   = { port = 9090, dns_name = "prometheus" }
      port_name      = "prometheus"
      discovery_name = "prometheus"
    }]
  }

  tasks_iam_role_statements = [{
    effect    = "Allow"
    actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
    resources = [dependency.efs.outputs.arn]
  }]
}
