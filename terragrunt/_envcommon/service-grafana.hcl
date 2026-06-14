# _envcommon/service-grafana.hcl — Grafana UI on Fargate, behind the ALB.
# State (SQLite DB + dashboards) on EFS (/var/lib/grafana). Admin password from
# Secrets Manager. Its datasources (baked into the image) point at the Service
# Connect names http://loki:3100, http://tempo:3200, http://prometheus:9090.
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
  mock_outputs                            = { repository_urls = { grafana = "111122223333.dkr.ecr.us-west-2.amazonaws.com/wt-grafana" } }
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
dependency "alb" {
  config_path                             = "../alb"
  mock_outputs                            = { target_groups = { grafana = { arn = "arn:aws:elasticloadbalancing:us-west-2:111122223333:targetgroup/mock/0" } } }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}
dependency "secrets" {
  config_path                             = "../secrets"
  mock_outputs                            = { secret_arns = { "grafana-admin-password" = "arn:aws:secretsmanager:us-west-2:111122223333:secret:watchtower/x/grafana-admin-password" } }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}

inputs = {
  name          = "watchtower-${local.env.environment}-grafana"
  cluster_arn   = dependency.cluster.outputs.cluster_arn
  cpu           = local.env.sizes.grafana.cpu
  memory        = local.env.sizes.grafana.memory
  desired_count = local.env.desired_count

  runtime_platform = { cpu_architecture = "ARM64", operating_system_family = "LINUX" }

  container_definitions = {
    grafana = {
      essential     = true
      image         = "${dependency.ecr.outputs.repository_urls["grafana"]}:${local.env.image_tag}"
      port_mappings = [{ name = "grafana", containerPort = 3000, protocol = "tcp" }]

      environment = concat(
        [
          { name = "GF_SECURITY_ADMIN_USER", value = "admin" },
          { name = "AWS_REGION", value = local.region.aws_region },
        ],
        local.grafana_url != "" ? [{ name = "GF_SERVER_ROOT_URL", value = local.grafana_url }] : [],
      )
      secrets = [
        { name = "GF_SECURITY_ADMIN_PASSWORD", valueFrom = dependency.secrets.outputs.secret_arns["grafana-admin-password"] },
      ]

      mount_points             = [{ sourceVolume = "grafana", containerPath = "/var/lib/grafana", readOnly = false }]
      readonly_root_filesystem = false
    }
  }

  volume = {
    grafana = {
      efs_volume_configuration = {
        file_system_id     = dependency.efs.outputs.id
        transit_encryption = "ENABLED"
        authorization_config = {
          access_point_id = dependency.efs.outputs.access_points["grafana"].id
          iam             = "ENABLED"
        }
      }
    }
  }

  subnet_ids            = dependency.vpc.outputs.private_subnets
  security_group_ids    = [dependency.sg.outputs.app_sg_id]
  create_security_group = false
  assign_public_ip      = false

  load_balancer = {
    grafana = {
      target_group_arn = dependency.alb.outputs.target_groups["grafana"].arn
      container_name   = "grafana"
      container_port   = 3000
    }
  }

  # Grafana is a Service Connect CLIENT (it calls loki/tempo/prometheus); it
  # isn't reached by other tasks, so no advertised service block.
  service_connect_configuration = {
    enabled   = true
    namespace = dependency.cluster.outputs.namespace_arn
  }

  task_exec_secret_arns = [dependency.secrets.outputs.secret_arns["grafana-admin-password"]]

  tasks_iam_role_statements = [{
    effect    = "Allow"
    actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
    resources = [dependency.efs.outputs.arn]
  }]
}
