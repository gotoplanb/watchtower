# _envcommon/service-tempo.hcl — Tempo (traces) on Fargate, S3-backed.
# Advertises itself on the Service Connect namespace as tempo:3200 so Grafana
# + Alloy reach it by name. Task role grants its S3 bucket.
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
  mock_outputs                            = { repository_urls = { tempo = "111122223333.dkr.ecr.us-west-2.amazonaws.com/wt-tempo" } }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}
dependency "s3" {
  config_path                             = "../s3"
  mock_outputs                            = { bucket_names = { tempo = "wt-tempo-mock" }, bucket_arns = { tempo = "arn:aws:s3:::wt-tempo-mock" } }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}

inputs = {
  name          = "watchtower-${local.env.environment}-tempo"
  cluster_arn   = dependency.cluster.outputs.cluster_arn
  cpu           = local.env.sizes.tempo.cpu
  memory        = local.env.sizes.tempo.memory
  desired_count = local.env.desired_count

  runtime_platform = { cpu_architecture = "ARM64", operating_system_family = "LINUX" }

  container_definitions = {
    tempo = {
      essential     = true
      image         = "${dependency.ecr.outputs.repository_urls["tempo"]}:${local.env.image_tag}"
      port_mappings = [{ name = "tempo", containerPort = 3200, protocol = "tcp" }]
      # The baked tempo config reads these (config.expand-env) to point its
      # storage backend at S3.
      environment = [
        { name = "AWS_REGION", value = local.region.aws_region },
        { name = "TEMPO_S3_BUCKET", value = dependency.s3.outputs.bucket_names["tempo"] },
      ]
      readonly_root_filesystem = false
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
      client_alias   = { port = 3200, dns_name = "tempo" }
      port_name      = "tempo"
      discovery_name = "tempo"
    }]
  }

  tasks_iam_role_statements = [{
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [dependency.s3.outputs.bucket_arns["tempo"], "${dependency.s3.outputs.bucket_arns["tempo"]}/*"]
  }]
}
