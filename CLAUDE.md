# CLAUDE.md — Watchtower

Context for Claude Code sessions working on this project.

## What This Project Is

A local LGTM-style observability stack for testing OpenTelemetry instrumentation. Grafana Alloy is the OTLP receiver and routes traces → Tempo, logs → Loki, metrics → Prometheus (via remote-write). Grafana is pre-provisioned with all three datasources and cross-links between them. The spec lives at `watchtower-spec.pdf`.

The repo supports **two deployment paths**:

1. **Docker Compose (default, what's running today)** — `docker-compose.yml` + `docker/` configs. This is the simpler path and what the active development is on.
2. **Kind + Helm (alternative)** — `kind/cluster-config.yaml` + `helm/values/*.yaml` + `alloy/config.alloy`. More complex; uses `mimir-distributed` instead of plain Prometheus. Kept around for learning Helm/k8s patterns.

If the user just says "the stack," they almost certainly mean the docker-compose one. Run `docker ps` to confirm what's actually up.

## Docker Compose Path (primary)

### Containers and ports

| Service | Container | Host Port | Notes |
|---------|-----------|-----------|-------|
| Grafana | `watchtower-grafana` | 3000 | admin / watchtower |
| OTLP gRPC | `watchtower-alloy` | 4317 | send telemetry here |
| OTLP HTTP | `watchtower-alloy` | 4318 | |
| Alloy UI | `watchtower-alloy` | 12345 | `/metrics`, debug graph |
| Tempo API | `watchtower-tempo` | 3200 | |
| Loki API | `watchtower-loki` | 3100 | |
| Prometheus UI | `watchtower-prometheus` | 9090 | remote-write enabled |
| SonarQube | `watchtower-sonarqube` | 9000 | unrelated to LGTM, code quality |
| SonarQube DB | `watchtower-sonarqube-db` | (internal) | |

These are the actual standard ports. **Don't trust port docs that mention 13000 / 14317 / 14318** — those are the kind-cluster remapped ports, not what compose uses.

### Common operations

```bash
make docker-up         # Start the stack
make docker-down       # Stop
make docker-logs       # Tail Alloy
make docker-status     # docker-compose ps
make docker-clean      # Down + delete volumes (wipes data)
```

### Configs (bind-mounted into containers)

- `docker/alloy-config.alloy` — OTLP receiver → Tempo / Loki / Prometheus pipeline
- `docker/tempo-config.yaml`, `docker/loki-config.yaml`, `docker/prometheus.yaml`
- `docker/grafana-datasources.yaml` — pre-provisioned Tempo/Loki/Prometheus DS

To pick up an Alloy config edit: `docker compose restart alloy`. The file is bind-mounted, no rebuild needed.

### Alloy pipeline (current docker-compose config)

```
otelcol.receiver.otlp ─► otelcol.processor.batch ─┬─► otelcol.exporter.otlp.tempo (gRPC :4317)
                                                  ├─► otelcol.exporter.prometheus ─► prometheus.remote_write (http://prometheus:9090/api/v1/write)
                                                  └─► otelcol.exporter.loki ─► loki.write (http://loki:3100/loki/api/v1/push)
```

The Grafana Cloud dual-export branch was removed (commit 39cf936). The compose config now reads `.env.grafana-cloud` only if it exists (`required: false` in compose) — safe to ignore.

## Querying the Backends

When verifying telemetry end-to-end, the right labels matter:

- **Loki**: the OTLP→Loki exporter maps `service.name` resource attribute to the Loki label **`job`**, NOT `service_name`. Available stream labels are `exporter`, `job`, `level`. Query example: `{job="watchtower-generator"}`.
- **Prometheus**: OTLP resources land as the `target_info` metric and as `job=<service.name>` labels on data points. Query series with `{job="watchtower-generator"}`.
- **Tempo**: search by service name with `rootServiceName` in `/api/search` results.

Quick health probes:
```bash
curl -s 'http://localhost:3200/api/search?limit=5'                            # Tempo
curl -s 'http://localhost:3100/loki/api/v1/labels'                            # Loki
curl -s 'http://localhost:9090/api/v1/label/__name__/values' | head -c 500    # Prom
curl -s 'http://localhost:12345/metrics' | grep otelcol_receiver_accepted     # Alloy throughput
```

## Known Issue: Sparse OTLP Metrics

OTLP histogram and counter metrics from instrumented apps don't show up well in Prometheus through `otelcol.exporter.prometheus` + `prometheus.remote_write`. Confirmed by counter comparison during testing on 2026-04-27:

- `otelcol_receiver_accepted_metric_points_total` ~ 426
- `prometheus_remote_storage_samples_in_total` ~ 35

So ~12× of metric points are dropped before reaching Prom. Only `target_info` reliably appears for the `watchtower-generator` job. Traces and logs flow through with no losses.

Likely culprits to investigate when this becomes important: temporality mismatch (cumulative vs delta), metric name suffix translation, or `otelcol.exporter.prometheus` configuration (try `add_metric_suffixes`, `gauge_to_counter`, etc.). Not yet root-caused.

## Test Data Generator

`test-data/generate.py` uses the OpenTelemetry Python SDK to send synthetic traces, metrics, and logs via OTLP gRPC. Uses a venv at `test-data/.venv` (Python 3.9).

```bash
cd test-data && ./.venv/bin/python generate.py --endpoint localhost:4317 --rate 10 --error-rate 0.05
```

Simulates `api-gateway` → `order-service` → `payment-service` calls under one resource (`service.name=watchtower-generator`). Produces correlated traces (one trace per request), structured logs (with `trace_id`/`span_id`), and 3 instruments: `http.server.request.count`, `http.server.request.duration` (histogram), `http.server.error.count`.

The `make test-data` target uses system pip and the wrong port (`14317`) — prefer the venv invocation above. Should be fixed.

## Kind + Helm Path (secondary)

This path still works and the gotchas below remain valid if you actually deploy it. But the active stack is docker-compose; treat this as legacy/alt.

### Helm charts

All from `https://grafana.github.io/helm-charts`. Values in `helm/values/`. Charts: `grafana/tempo`, `grafana/loki`, `grafana/mimir-distributed`, `grafana/grafana`, `grafana/alloy`.

### Mimir Chart Gotchas (mimir-distributed ~3.0.1)

The chart assumes a production cloud setup. For local dev with filesystem storage:

1. **Kafka/ingest_storage**: chart defaults `ingest_storage.enabled: true` with Kafka. Set both `mimir.structuredConfig.ingest_storage.enabled: false` AND `kafka.enabled: false`.
2. **push_grpc_method_enabled**: when ingest_storage is disabled, the chart still sets this to `false` (Kafka-only setting). Set `ingester.push_grpc_method_enabled: true` in structuredConfig or the ingester refuses writes.
3. **multitenancy_enabled**: must be `false` — otherwise Alloy writes get 401 "no org id" because we don't send `X-Scope-OrgID` headers.
4. **query_scheduler**: do NOT disable. The query-frontend hard-depends on it and CrashLoops with "missing address" if removed.
5. **Compactor path overlap**: `blocks_storage.filesystem.dir` must not be under `/data` — it overlaps with the compactor's data_dir. Use `/data/mimir-blocks` and `/data/mimir-compactor`.
6. **zoneAwareReplication**: `false` on ingester and store_gateway for single-replica local dev.
7. **rollout_operator**: disable. Not needed for local; just adds a pod.

### Loki Chart Gotchas

- Disable `chunksCache` and `resultsCache` — they deploy memcached pods that won't schedule on a resource-constrained kind cluster.
- `auth_enabled: false` — Alloy doesn't send tenant headers.
- `deploymentMode: SingleBinary`; set `backend/read/write` replicas to 0.

### Alloy Component Names (v1.12.x)

Verified working:
- `otelcol.exporter.prometheusremotewrite` does **not exist**. Use `otelcol.exporter.prometheus` + `prometheus.remote_write` two-stage pipeline.
- For Tempo, use `otelcol.exporter.otlp` (gRPC :4317), NOT `otelcol.exporter.otlphttp`. Tempo's gRPC receiver is more reliable.
- `otelcol.exporter.loki` + `loki.write` works for logs.

### Alloy Config in the Helm Path

- `alloy/config.alloy` — dual-write (local LGTM + Sumo Logic).
- `alloy/config-local-only.alloy` — local LGTM only, no Sumo dependency.
- Loaded into a ConfigMap (`alloy-config`) by `make deploy-alloy`. Helm chart told `configMap.create: false`.
- Switch with `make enable-local-only` / `make disable-local-only`.

### Alloy NodePort Patch (Helm path only)

The Alloy chart's `extraPorts` adds service ports but doesn't let you set specific `nodePort` values. After `make deploy-alloy`, OTLP NodePorts are random. Pin them with:

```bash
kubectl patch svc alloy -n watchtower --type='json' -p='[
  {"op":"replace","path":"/spec/ports/1/nodePort","value":30317},
  {"op":"replace","path":"/spec/ports/2/nodePort","value":30318}
]'
```

This patch does NOT survive `helm upgrade`. Re-run after each redeploy. A post-deploy hook or custom service manifest would be a good fix.

### Sumo Logic (Helm path)

- OTLP endpoint in K8s secret `sumo-credentials` (key: `endpoint`) in namespace `watchtower`.
- Alloy reads via `env("SUMO_OTLP_ENDPOINT")` using `extraEnv` with `secretKeyRef` in `helm/values/alloy.yaml`.
- If the secret is missing, Alloy CrashLoops. Switch to local-only mode if Sumo isn't needed.

## Things That Could Be Improved

- Root-cause the OTLP→Prometheus metric dropoff (see Known Issue above).
- Make the Alloy NodePort patch durable (post-install hook or custom service manifest).
- Update `make test-data` to use the venv and port 4317 instead of system pip and port 14317.
- Build Grafana dashboards in `dashboards/` (currently empty).
