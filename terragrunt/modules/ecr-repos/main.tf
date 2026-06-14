# ============================================================================
# ecr-repos — one ECR repository per LGTM/Alloy service
# ============================================================================
# Each service runs a thin image: FROM the upstream image + COPY the AWS config
# (see README "Baked config images"). One repo per service keeps tags clean.

variable "name_prefix" { type = string } # e.g. "watchtower-prod"
variable "services" {
  type    = list(string)
  default = ["tempo", "loki", "prometheus", "grafana", "alloy"]
}

resource "aws_ecr_repository" "this" {
  for_each             = toset(var.services)
  name                 = "${var.name_prefix}-${each.value}"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 10 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# Map of service -> repository URL, consumed by each service unit.
output "repository_urls" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}
