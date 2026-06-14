# _envcommon/service-alloy.hcl — Alloy (OTLP collector) on Fargate, behind the
# INTERNAL NLB. Receives OTLP from Conduct (gRPC 4317 / HTTP 4318) and fans out
# to the in-cluster backends via Service Connect (loki:3100, tempo:3200,
# prometheus:9090 remote-write) — all baked into its config.
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
  mock_outputs                            = { repository_urls = { alloy = "111122223333.dkr.ecr.us-west-2.amazonaws.com/wt-alloy" } }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}
dependency "nlb" {
  config_path = "../nlb"
  mock_outputs = {
    target_groups = {
      otlp_grpc = { arn = "arn:aws:elasticloadbalancing:us-west-2:111122223333:targetgroup/grpc/0" }
      otlp_http = { arn = "arn:aws:elasticloadbalancing:us-west-2:111122223333:targetgroup/http/0" }
    }
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}

inputs = {
  name          = "watchtower-${local.env.environment}-alloy"
  cluster_arn   = dependency.cluster.outputs.cluster_arn
  cpu           = local.env.sizes.alloy.cpu
  memory        = local.env.sizes.alloy.memory
  desired_count = local.env.desired_count

  runtime_platform = { cpu_architecture = "ARM64", operating_system_family = "LINUX" }

  container_definitions = {
    alloy = {
      essential = true
      image     = "${dependency.ecr.outputs.repository_urls["alloy"]}:${local.env.image_tag}"
      port_mappings = [
        { name = "otlp-grpc", containerPort = 4317, protocol = "tcp" },
        { name = "otlp-http", containerPort = 4318, protocol = "tcp" },
      ]
      environment              = [{ name = "AWS_REGION", value = local.region.aws_region }]
      readonly_root_filesystem = false
    }
  }

  subnet_ids            = dependency.vpc.outputs.private_subnets
  security_group_ids    = [dependency.sg.outputs.app_sg_id]
  create_security_group = false
  assign_public_ip      = false

  load_balancer = {
    otlp_grpc = {
      target_group_arn = dependency.nlb.outputs.target_groups["otlp_grpc"].arn
      container_name   = "alloy"
      container_port   = 4317
    }
    otlp_http = {
      target_group_arn = dependency.nlb.outputs.target_groups["otlp_http"].arn
      container_name   = "alloy"
      container_port   = 4318
    }
  }

  # Alloy is a Service Connect CLIENT (forwards to the backends by name).
  service_connect_configuration = {
    enabled   = true
    namespace = dependency.cluster.outputs.namespace_arn
  }
}
