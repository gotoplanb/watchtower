# ============================================================================
# security-groups (Watchtower) — all SGs, cross-wired
# ============================================================================
# Two SGs:
#  - alb: public 80/443 for the Grafana UI.
#  - app: every LGTM/Alloy task. Allows (a) Grafana :3000 from the ALB,
#    (b) OTLP 4317/4318 from the peered Conduct CIDRs (Alloy ingest),
#    (c) ALL traffic from ITSELF — intra-stack service-to-service (Grafana→Loki
#    :3100, →Tempo :3200, →Prometheus :9090; Alloy→those) over ECS Service
#    Connect happens task-to-task within this SG.

variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "otlp_allowed_cidrs" {
  type    = list(string)
  default = []
}
variable "grafana_port" {
  type    = number
  default = 3000
}

resource "aws_security_group" "alb" {
  name_prefix = "${var.name_prefix}-alb-"
  description = "Watchtower ALB — public ingress to Grafana"
  vpc_id      = var.vpc_id
  lifecycle { create_before_destroy = true }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}
resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "app" {
  name_prefix = "${var.name_prefix}-app-"
  description = "Watchtower LGTM + Alloy tasks"
  vpc_id      = var.vpc_id
  lifecycle { create_before_destroy = true }
}

# Grafana from the ALB only.
resource "aws_vpc_security_group_ingress_rule" "grafana_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.grafana_port
  to_port                      = var.grafana_port
  ip_protocol                  = "tcp"
  description                  = "ALB to Grafana"
}

# OTLP (gRPC 4317 + HTTP 4318) into Alloy from the peered Conduct CIDRs. The
# internal NLB preserves client IP, so these CIDR rules apply to the task.
resource "aws_vpc_security_group_ingress_rule" "otlp" {
  for_each          = { for pair in setproduct(var.otlp_allowed_cidrs, [4317, 4318]) : "${pair[0]}-${pair[1]}" => { cidr = pair[0], port = pair[1] } }
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = each.value.cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
  description       = "OTLP from Conduct ${each.value.cidr}"
}

# Intra-stack: any task may talk to any other on any port (Service Connect:
# Grafana→Loki/Tempo/Prometheus, Alloy→backends). Scoped to this SG only.
resource "aws_vpc_security_group_ingress_rule" "intra" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "-1"
  description                  = "Intra-stack service-to-service"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

output "alb_sg_id" { value = aws_security_group.alb.id }
output "app_sg_id" { value = aws_security_group.app.id }
