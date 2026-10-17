# Upgrade backlog

Running state for the scheduled dependency check. Patch and minor bumps get
applied automatically; **majors wait for a decision** and live here so the
routine doesn't re-report the same ones every day.

Update the "last checked" date and the rows below whenever the check runs.

## Last checked: 2026-10-17

Every pin is at the top of its current series — **no patch or minor upgrade was
available**, nothing applied.

| Pin | Current | Newest in series | Source |
|-----|---------|------------------|--------|
| `grafana/tempo` | 2.10.8 | 2.10.8 | Docker Hub |
| `grafana/loki` | 2.9.17 | 2.9.17 (last pushed 2025-11-07) | Docker Hub |
| `prom/prometheus` | v3.15.0 | v3.15.0 | Docker Hub |
| `grafana/grafana` | 13.2.4 | 13.2.4 | Docker Hub |
| `grafana/alloy` | v1.20.1 | v1.20.1 (v1.21.0-rc.0 is pre-release) | Docker Hub |
| `sonarqube` | 26.10.0.133078-community | same | Docker Hub |
| `terraform-aws-modules/ecs` | 5.12.1 | 5.12.1 (last of 5.x) | TF Registry |
| `terraform-aws-modules/vpc` | 5.21.0 | 5.21.0 (last of 5.x) | TF Registry |
| `terraform-aws-modules/alb` | 9.17.0 | 9.17.0 (last of 9.x) | TF Registry |
| `terraform-aws-modules/efs` | 1.8.1 | 1.8.1 (last of 1.x) | TF Registry |
| `terraform-aws-modules/acm` | 5.2.0 | 5.2.0 (last of 5.x) | TF Registry |

`postgres:16-alpine` and `rust:1-slim-bookworm` are major-pinned floating tags —
patch/minor arrive on their own with a `docker compose pull`. `test-data/requirements.txt`
uses `>=` constraints, so there is nothing to bump there either.

## Where to look things up

`hub.docker.com` and `registry.terraform.io` are **not reachable** from the
scheduled run (the proxy answers 403 to CONNECT, from both the cloud container
and the device shell), and the `gh` CLI has no access to these upstream repos.
Don't burn a run retrying them. What works, via web fetch:

- `https://releasealert.dev/github/<org>/<repo>` — tag list with dates and
  RC flags (tempo, loki, alloy); `/dockerhub/<org>/<image>` for image tags.
- `https://prometheus.io/download.json` — Prometheus stable/LTS.
- `https://versionlog.com/grafana/<branch>/` — Grafana point releases.
- `https://endoflife.date/sonarqube-community` — SonarQube build + EOL dates.
- `https://registry.terraform.io/v1/modules/<ns>/<name>/aws/versions` — works
  through web fetch even though curl is blocked.

## Majors awaiting a decision

Each of these is the *next* step up from a series that has stopped receiving
releases, so the patch/minor stream is dry until one is taken.

| Component | Current | Latest | Notes |
|-----------|---------|--------|-------|
| `grafana/tempo` | 2.10.8 | 3.1.0 | Big config migration. `ingester`/`ingester_client`/`compactor`/`metrics_generator_client` blocks are **removed**; legacy flat overrides block startup (`tempo-cli migrate overrides-config`); block/WAL settings move under `storage.trace.block`; `query_ingesters_until` → `query_backend_after`; TraceQL `!=`/`!~` behavior on array attributes changed. `tempo-cli migrate config` automates most of it. The 3.0 line is still maintained (3.0.4, 2026-10-16) if 3.1 looks too fresh. |
| `grafana/loki` | 2.9.17 | 3.7.8 | 2.9.x has had no release in ~12 months. Loki 3 wants TSDB + schema v13 and reshuffles config; the OTLP→Loki write path and the `job`/`exporter`/`level` labels this repo relies on are worth re-verifying with `make smoke` after. The 3.6 line (3.6.17) is the conservative landing spot. |
| `terraform-aws-modules/ecs` | 5.12.1 | 7.6.1 | Two majors behind; the `//modules/service` interface changed. Affects all five `service-*.hcl`. |
| `terraform-aws-modules/vpc` | 5.21.0 | 6.7.3 | — |
| `terraform-aws-modules/alb` | 9.17.0 | 10.5.1 | Used by both `alb.hcl` and `nlb.hcl`. |
| `terraform-aws-modules/efs` | 1.8.1 | 2.2.1 | — |
| `terraform-aws-modules/acm` | 5.2.0 | 6.3.1 | — |

The Terragrunt stack isn't the active path (docker-compose is), so those five can
move together whenever the AWS side gets attention. Tempo and Loki are the ones
that matter for the local stack, and each should be done alone, with
`make verify` after.

## Reminders when a bump does land

- `make test` guards the compose pins (static, no daemon). `make smoke` proves
  telemetry actually arrives — container health only proves the process booted.
- A SonarQube bump needs a manual DB migration trigger and is one-way; dump the
  DB first. See CLAUDE.md.
- Check what's inside an image before touching its healthcheck. See CLAUDE.md.
