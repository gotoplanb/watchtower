# _envcommon/alb.hcl (Watchtower) — public ALB for the Grafana UI only.
# Everything else (Loki/Tempo/Prometheus/Alloy) is internal.
locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "tfr:///terraform-aws-modules/alb/aws//.?version=9.11.0"
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id         = "vpc-00000000000000000"
    public_subnets = ["subnet-pub-a", "subnet-pub-b", "subnet-pub-c"]
  }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}
dependency "sg" {
  config_path                             = "../security-groups"
  mock_outputs                            = { alb_sg_id = "sg-alb0000" }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}
dependency "acm" {
  config_path                             = "../acm"
  mock_outputs                            = { acm_certificate_arn = "arn:aws:acm:us-west-2:111122223333:certificate/mock" }
  mock_outputs_allowed_terraform_commands = ["plan", "validate", "init"]
}

inputs = {
  name    = "wt-${local.env.environment}-grafana"
  vpc_id  = dependency.vpc.outputs.vpc_id
  subnets = dependency.vpc.outputs.public_subnets

  create_security_group = false
  security_groups       = [dependency.sg.outputs.alb_sg_id]

  enable_deletion_protection = local.env.environment == "prod"

  target_groups = {
    grafana = {
      name_prefix       = "wtg-"
      protocol          = "HTTP"
      port              = 3000
      target_type       = "ip"
      create_attachment = false
      health_check = {
        path     = "/api/health"
        matcher  = "200"
        interval = 15
        timeout  = 5
      }
    }
  }

  listeners = {
    http_redirect = {
      port     = 80
      protocol = "HTTP"
      redirect = { port = "443", protocol = "HTTPS", status_code = "HTTP_301" }
    }
    https = {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = dependency.acm.outputs.acm_certificate_arn
      forward         = { target_group_key = "grafana" }
    }
  }
}
