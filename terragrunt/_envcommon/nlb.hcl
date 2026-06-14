# _envcommon/nlb.hcl (Watchtower) — INTERNAL network load balancer fronting
# Alloy's OTLP receivers (gRPC 4317 + HTTP 4318). Conduct reaches this over VPC
# peering. NLB (not ALB) because OTLP/gRPC is raw TCP/HTTP2 and we want client
# IP preserved so the app SG's CIDR rules apply. internal = true → no public IP.
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "tfr:///terraform-aws-modules/alb/aws//.?version=9.11.0"
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id          = "vpc-00000000000000000"
    private_subnets = ["subnet-a", "subnet-b", "subnet-c"]
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}
dependency "sg" {
  config_path                             = "../security-groups"
  mock_outputs                            = { app_sg_id = "sg-app0000" }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}

inputs = {
  name               = "wt-${local.env.environment}-otlp"
  load_balancer_type = "network"
  internal           = true
  vpc_id             = dependency.vpc.outputs.vpc_id
  subnets            = dependency.vpc.outputs.private_subnets

  # Reuse the app SG (it already allows 4317/4318 from the Conduct CIDRs).
  create_security_group = false
  security_groups       = [dependency.sg.outputs.app_sg_id]

  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = local.env.environment == "prod"

  target_groups = {
    otlp_grpc = {
      name_prefix       = "wtg-"
      protocol          = "TCP"
      port              = 4317
      target_type       = "ip"
      create_attachment = false
      health_check      = { protocol = "TCP" }
    }
    otlp_http = {
      name_prefix       = "wth-"
      protocol          = "TCP"
      port              = 4318
      target_type       = "ip"
      create_attachment = false
      health_check      = { protocol = "TCP" }
    }
  }

  listeners = {
    grpc = { port = 4317, protocol = "TCP", forward = { target_group_key = "otlp_grpc" } }
    http = { port = 4318, protocol = "TCP", forward = { target_group_key = "otlp_http" } }
  }
}
