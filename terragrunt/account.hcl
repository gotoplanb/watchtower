# ============================================================================
# Account-wide constants (Watchtower, single-account topology)
# ============================================================================
# Same account as Conduct (single-account topology) but its OWN state bucket +
# lock table, so the two stacks never touch each other's state.

locals {
  account_id   = "111122223333" # TODO: your AWS account id (same as Conduct)
  account_name = "watchtower"

  # ---- Remote state backend (separate from Conduct's) -----------------------
  state_region = "us-west-2"
  state_bucket = "watchtower-tfstate-111122223333" # TODO: globally-unique
  lock_table   = "watchtower-tflocks"

  # ---- Public DNS / TLS for the Grafana UI ----------------------------------
  # The Grafana web UI is the only public surface. Loki/Tempo/Prometheus/Alloy
  # are internal-only. Leave blank to skip ACM/DNS and reach Grafana via the raw
  # ALB DNS name on HTTP.
  hosted_zone_name = "" # e.g. "example.com"
  hosted_zone_id   = "" # e.g. "Z0123456789ABCDEFGHIJ"
  domain_base      = "" # e.g. "grafana.example.com" (env subdomains derived)

  # ---- Cross-stack: who may send OTLP to Alloy ------------------------------
  # After VPC-peering Conduct ⇄ Watchtower, Alloy's internal NLB + SG accept
  # OTLP only from these CIDRs. These are Conduct's VPC CIDRs (see Conduct's
  # region.hcl files). Keep in sync if you add Conduct regions/envs.
  otlp_allowed_cidrs = [
    "10.10.0.0/16", # conduct prod us-west-2
    "10.11.0.0/16", # conduct prod us-east-2
    "10.20.0.0/16", # conduct dev  us-west-2
  ]
}
