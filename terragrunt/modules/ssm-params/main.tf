# ============================================================================
# ssm-params — publish Watchtower's endpoints for Conduct to discover
# ============================================================================
# The cross-stack handshake: Watchtower writes its OTLP endpoint (Alloy's
# internal NLB) and Grafana URL to SSM Parameter Store under well-known names.
# Conduct reads these (today by copying into its env.hcl; later via a data
# source) so the two stacks stay decoupled — neither references the other's
# Terraform state.

variable "env" { type = string }
variable "region" { type = string }
variable "otlp_endpoint" { type = string } # e.g. http://otlp.watchtower.internal:4317
variable "grafana_url" { type = string }   # e.g. https://grafana.example.com

locals {
  prefix = "/watchtower/${var.env}/${var.region}"
}

resource "aws_ssm_parameter" "otlp_endpoint" {
  name  = "${local.prefix}/otlp-endpoint"
  type  = "String"
  value = var.otlp_endpoint
}

resource "aws_ssm_parameter" "grafana_url" {
  name  = "${local.prefix}/grafana-url"
  type  = "String"
  value = var.grafana_url
}

output "otlp_param_name" { value = aws_ssm_parameter.otlp_endpoint.name }
output "grafana_param_name" { value = aws_ssm_parameter.grafana_url.name }
