# Upgrade backlog

State for the dependency update, done by hand with Claude roughly every two
weeks on Dave's machine (there is no scheduled job: one existed until 2026-10-24,
but it had no `docker`, so it committed pins it could never deploy or smoke).
Patch and minor bumps get applied in the session; **majors wait for a decision**
and live in the table at the bottom.

## Update checklist

1. Look up the newest release in each series (sources below) and bump the pins.
2. `make test` -- pins are real versions, no floating tags.
3. `docker ps` vs `grep image: docker-compose.yml` -- the running images, not the
   repo, are what's live. They have drifted before.
4. SonarQube bump only: `pg_dump` to `~/watchtower-backups/` first, then
   `migrate_db` after it starts (one-way; see CLAUDE.md).
5. `docker compose pull && docker compose up -d`, `docker compose build --pull rust-build`,
   then `make smoke`.
6. `make scan` -- CVEs in the images now running. Note anything critical with a fix
   below; a pull/rebuild has already cleared what a stale local copy caused.
7. Update the "last updated" date and table below, commit, push.

## Last updated: 2026-10-24

All pins below are deployed and pass `make smoke` (all four stages, including the
Grafana proxy path). SonarQube was migrated 26.9.0 -> 26.10.0 with a DB dump
taken first.

| Pin | Current | Newest in series | Source |
|-----|---------|------------------|--------|
| `grafana/tempo` | 2.10.10 | 2.10.10 (2026-10-21) | releasealert/dockerhub |
| `grafana/loki` | 2.9.17 | 2.9.17 (2025-11-07; still no newer 2.9.x; newest 3.x is 3.7.9, 2026-10-20) | releasealert/github |
| `prom/prometheus` | v3.15.1 | v3.15.1 (LTS line v3.13.5) | prometheus.io |
| `grafana/grafana` | 13.2.5 | 13.2.5 (2026-10-27; HTTP2Shell fix; still no 13.3 branch) | Docker Hub API |
| `grafana/alloy` | **v1.21.2** | v1.21.2 (2026-10-22) | releasealert github+dockerhub |
| `sonarqube` | 26.10.0.133078-community | same (26.10, 2026-10-12) | endoflife.date |
| `terraform-aws-modules/ecs` | 5.12.1 | 5.12.1 (last of 5.x) | TF Registry |
| `terraform-aws-modules/vpc` | 5.21.0 | 5.21.0 (last of 5.x) | TF Registry |
| `terraform-aws-modules/alb` | 9.17.0 | 9.17.0 (last of 9.x) | TF Registry |
| `terraform-aws-modules/efs` | 1.8.1 | 1.8.1 (last of 1.x) | TF Registry |
| `terraform-aws-modules/acm` | 5.2.0 | 5.2.0 (last of 5.x) | TF Registry |

`postgres:16-alpine` and `rust:1-slim-bookworm` are major-pinned floating tags --
patch/minor arrive on their own with a `docker compose pull`. `test-data/requirements.txt`
uses `>=` constraints, so there is nothing to bump there either.

### Tempo: use the Docker Hub view, not the GitHub view

On 2026-10-23 `releasealert.dev/github/grafana/tempo` showed 2.10.9 (10-20) as
the newest 2.10.x and omitted 2.10.10, 3.0.5 and 3.1.1 entirely -- i.e. it was
missing everything published on 10-21, even though the *same site's* alloy page
had 10-21 data. Trusting it, you would conclude the committed 2.10.10 pin
points at a nonexistent image and is tempted to "fix" it by reverting.

`releasealert.dev/dockerhub/grafana/tempo` is current and lists 2.10.10, 3.0.5
and 3.1.1 all dated 10-21; a web search surfaces the real
`github.com/grafana/tempo/releases/tag/v2.10.10` page. **Check tempo against the
dockerhub view, and never revert a pin on the strength of one absent listing.**

## Where to look things up

From Dave's machine `curl` to Docker Hub and the Terraform Registry works, so
those are the most direct check. If you're going through web fetch instead:

**GitHub itself is worse than useless here:** `github.com/<org>/<repo>/releases`
and raw `CHANGELOG.md` fetched through web fetch return a cached crawl roughly
two months old (on 2026-10-22 it showed Tempo's newest as v2.10.8/13 Aug and
Prometheus's as v3.14.0, both wrong by several releases). It looks authoritative
and it is not -- trusting it, you would conclude the current pins are ahead
of upstream and "fabricated". Cross-check against the sources below, which are
current.

- `https://releasealert.dev/github/<org>/<repo>` — tag list with dates and
  RC flags (tempo, loki, alloy); `/dockerhub/<org>/<image>` for image tags.
- `https://prometheus.io/download.json` — Prometheus stable/LTS.
- `https://versionlog.com/grafana/<branch>/` — Grafana point releases.
- `https://endoflife.date/sonarqube-community` — SonarQube build + EOL dates.
- `https://registry.terraform.io/v1/modules/<ns>/<name>/aws/versions` — works
  through web fetch even though curl is blocked.

`releasealert.dev/dockerhub/grafana/loki` is **not** usable for checking an old
series: the tag list is sorted newest-push-first and is ~420 pages of `main-<sha>`
CI tags, so a 2.9.x tag never appears. Use the GitHub release list
(`/github/grafana/loki`) and read the series off that instead.

## Majors awaiting a decision

Each of these is the *next* step up from a series that has stopped receiving
releases, so the patch/minor stream is dry until one is taken.

| Component | Current | Latest | Notes |
|-----------|---------|--------|-------|
| `grafana/tempo` | 2.10.10 | 3.1.1 | Big config migration. `ingester`/`ingester_client`/`compactor`/`metrics_generator_client` blocks are **removed**; legacy flat overrides block startup (`tempo-cli migrate overrides-config`); block/WAL settings move under `storage.trace.block`; `query_ingesters_until` → `query_backend_after`; TraceQL `!=`/`!~` behavior on array attributes changed. `tempo-cli migrate config` automates most of it. The 3.0 line is still maintained (3.0.5, 2026-10-21) if 3.1 looks too fresh. |
| `grafana/loki` | 2.9.17 | 3.7.9 | **Security reason to move:** `make scan` on 2026-10-27 found 4 critical + 74 high with fixes available (Go stdlib, grpc v1.59.0, alpine openssl) that 2.9.x will never get. 2.9.x has had no release in ~12 months. Loki 3 wants TSDB + schema v13 and reshuffles config; the OTLP→Loki write path and the `job`/`exporter`/`level` labels this repo relies on are worth re-verifying with `make smoke` after. The 3.6 line (3.6.19, 2026-10-20) is the conservative landing spot. |
| `terraform-aws-modules/ecs` | 5.12.1 | 7.6.1 | Two majors behind; the `//modules/service` interface changed. Affects all five `service-*.hcl`. |
| `terraform-aws-modules/vpc` | 5.21.0 | 6.7.3 | — |
| `terraform-aws-modules/alb` | 9.17.0 | 10.5.1 | Used by both `alb.hcl` and `nlb.hcl`. |
| `terraform-aws-modules/efs` | 1.8.1 | 2.2.1 | — |
| `terraform-aws-modules/acm` | 5.2.0 | 6.3.1 | — |

The Terragrunt stack isn't the active path (docker-compose is), so those five can
move together whenever the AWS side gets attention. Tempo and Loki are the ones
that matter for the local stack, and each should be done alone, with
`make verify` after.

## CVE scan, 2026-10-27 (first run)

After pulling `postgres:16-alpine` and rebuilding `rust-build` (375 -> 3 findings):

| Image | Crit / High (fixable) | Who fixes it |
|-------|-----------------------|--------------|
| `grafana/loki:2.9.17` | 4 / 74 | us -- take the Loki 3 major |
| `grafana/grafana:13.2.4` | 0 / 27 | upstream (Go deps); 13.2.5 taken same day |
| `postgres:16-alpine` | 1 / 25 | upstream (`gosu` Go stdlib) |
| `sonarqube:26.10` | 1 / 18 | upstream (netty in a jar) |
| `rust-build` | 0 / 3 | -- |
| alloy, tempo, prometheus | 0 / 0 | -- |

### HTTP2Shell (CVE-2026-111497), checked 2026-10-27

Buffer overflow in Brotli's **C** decoder (fixed in Brotli 1.0.10 / 1.1.1 / 1.2.1,
Node 22.23.4 / 24.22.1 / 26.12.1, Python `Brotli`/`brotlicffi` 1.2.1). Trivy knows
it, so `make scan` will flag it from now on.

- Was hit: `grafana/grafana:13.2.4` (alpine `brotli-libs` 1.2.0) -> **bumped to
  13.2.5**; `sonarqube:26.10.0` (ubuntu `libbrotli1`) -> same tag was rebuilt
  upstream on 10-27, **re-pulled**. Both rescanned clean; `make smoke` passes.
- Not affected: `github.com/andybalholm/brotli` in tempo/alloy/grafana is a pure-Go
  port, not the C decoder. Loki, Prometheus, Postgres, rust-build: no Brotli.
- Outside this repo: `conduct:local` and `crossover:local` carry Debian
  `libbrotli1` (fixed in `+deb12u1` / `+deb13u1`; a `--pull` rebuild clears it).

## Reminders when a bump lands

- `make test` guards the compose pins (static, no daemon). `make smoke` proves
  telemetry actually arrives — container health only proves the process booted.
- A SonarQube bump needs a manual DB migration trigger and is one-way; dump the
  DB first. See CLAUDE.md.
- Check what's inside an image before touching its healthcheck. See CLAUDE.md.
