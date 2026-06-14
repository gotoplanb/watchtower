# ============================================================================
# dev environment variables (Watchtower) — single region (us-west-2 only)
# ============================================================================
locals {
  environment = "dev"

  # One task each, smallest Fargate sizing. The LGTM components are modestly
  # sized in dev; bump in prod (see prod/env.hcl).
  desired_count = 1

  # Per-service CPU/MeMiB. Grafana + Prometheus get a bit more headroom.
  sizes = {
    tempo      = { cpu = 256, memory = 512 }
    loki       = { cpu = 256, memory = 512 }
    prometheus = { cpu = 512, memory = 1024 }
    grafana    = { cpu = 256, memory = 512 }
    alloy      = { cpu = 256, memory = 512 }
  }

  # Image tag for the baked LGTM config images (see README "Baked config
  # images"). Bump to the SHA/version you pushed.
  image_tag = "latest"

  # Grafana public URL override (else derived from account.hcl.domain_base).
  grafana_url_override = ""
}
