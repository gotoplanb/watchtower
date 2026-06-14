# ============================================================================
# prod environment variables (Watchtower) — multi-region (us-west-2 + us-east-2)
# ============================================================================
# NOTE on multi-region observability: each region runs its OWN full LGTM stack
# with its OWN S3 buckets — telemetry stays in-region. Conduct in us-east-2
# sends to Watchtower in us-east-2. Grafana is latency-routed so you hit the
# nearest one. (A single global Grafana querying both regions' backends is
# possible but more complex; per-region is the simpler, cheaper default —
# discussed in the README.)
locals {
  environment = "prod"

  desired_count = 1 # LGTM single-binary components don't horizontally scale trivially; scale up before out

  sizes = {
    tempo      = { cpu = 512, memory = 1024 }
    loki       = { cpu = 512, memory = 1024 }
    prometheus = { cpu = 1024, memory = 2048 }
    grafana    = { cpu = 512, memory = 1024 }
    alloy      = { cpu = 512, memory = 1024 }
  }

  image_tag = "latest"

  grafana_url_override = ""
}
