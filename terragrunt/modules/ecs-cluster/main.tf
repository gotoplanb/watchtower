# ============================================================================
# ecs-cluster (Watchtower) — Fargate cluster + Service Connect namespace
# ============================================================================
# Wraps the registry cluster module and adds an ECS Service Connect namespace
# (a Cloud Map HTTP namespace). With this, services that advertise a
# client_alias (loki/tempo/prometheus) are reachable by other tasks at
# http://loki:3100 etc. — no hardcoded IPs, no internal ALB per backend.

variable "cluster_name" { type = string }
variable "namespace_name" { type = string } # e.g. "watchtower-prod"

resource "aws_service_discovery_http_namespace" "this" {
  name        = var.namespace_name
  description = "Watchtower Service Connect namespace"
}

module "cluster" {
  source  = "terraform-aws-modules/ecs/aws//modules/cluster"
  version = "5.12.0"

  cluster_name     = var.cluster_name
  cluster_settings = [{ name = "containerInsights", value = "enabled" }]

  # Default Service Connect namespace for services in this cluster.
  cluster_service_connect_defaults = {
    namespace = aws_service_discovery_http_namespace.this.arn
  }

  fargate_capacity_providers = {
    FARGATE      = { default_capacity_provider_strategy = { weight = 1, base = 1 } }
    FARGATE_SPOT = { default_capacity_provider_strategy = { weight = 0 } }
  }
}

output "cluster_arn" { value = module.cluster.arn }
output "cluster_name" { value = module.cluster.name }
output "namespace_arn" { value = aws_service_discovery_http_namespace.this.arn }
