# Watchtower

Local observability infrastructure for LLM-assisted development. Gives coding agents (Claude Code, Cursor, etc.) fast feedback loops: **build → test → observe telemetry → adjust**.

The local LGTM stack (Loki, Grafana, Tempo, Prometheus) runs on your machine. [Grafana Alloy](https://grafana.com/docs/alloy/) receives OTLP telemetry and can dual-write to cloud backends (Grafana Cloud, Sumo Logic) for human review.

## Send Telemetry to Watchtower

**OTLP Endpoints (Docker Compose):**
```
gRPC: localhost:4317
HTTP: localhost:4318
```

**Environment variables** (works with any OpenTelemetry SDK):
```bash
export OTEL_SERVICE_NAME=my-app
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
```

**From a Docker container:** Use `host.docker.internal:4317` instead of `localhost`.

**Grafana UI:** http://localhost:3000 (login: `admin` / `watchtower`)

### Query Telemetry (for LLMs)

```bash
# Recent traces
curl -s 'http://localhost:3200/api/search?limit=10' | jq .

# Logs by service
curl -s 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={service_name="my-app"}' | jq .

# Prometheus metrics
curl -s 'http://localhost:9090/api/v1/query?query=up' | jq .
```

---

## Docker Compose Quick Start

The fastest way to get started. No Kubernetes knowledge required.

```bash
make docker-up      # Start the stack
make docker-status  # Check container health
make docker-logs    # Tail Alloy logs
make docker-down    # Stop the stack
```

| Service | URL / Address | Notes |
|---------|--------------|-------|
| Grafana | http://localhost:3000 | Login: `admin` / `watchtower` |
| OTLP gRPC | `localhost:4317` | Send traces/metrics/logs here |
| OTLP HTTP | `localhost:4318` | Alternative OTLP endpoint |
| Prometheus | http://localhost:9090 | Metrics UI |
| Loki | http://localhost:3100 | Logs API |
| Tempo | http://localhost:3200 | Traces API |

### Generate Test Data

```bash
cd test-data
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python generate.py --endpoint localhost:4317 --rate 10
```

Open Grafana and explore:
- **Tempo**: Explore > Tempo > Search > Run query
- **Loki**: Explore > Loki > `{service_name="watchtower-generator"}`
- **Prometheus**: Explore > Prometheus > `target_info`

Click a trace to see correlated logs (datasource cross-links are pre-configured).

### Instrument Your Own App

Point any OTLP-compatible SDK at `localhost:4317` (gRPC) or `localhost:4318` (HTTP).

**Python (Django/FastAPI/Flask):**
```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install
```
```bash
OTEL_SERVICE_NAME=my-app \
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
opentelemetry-instrument python app.py
```

**Node.js:**
```bash
npm install @opentelemetry/auto-instrumentations-node @opentelemetry/exporter-trace-otlp-grpc
```
```bash
OTEL_SERVICE_NAME=my-app \
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
node --require @opentelemetry/auto-instrumentations-node/register app.js
```

**Go:**
```go
import "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"

exporter, _ := otlptracegrpc.New(ctx,
    otlptracegrpc.WithEndpoint("localhost:4317"),
    otlptracegrpc.WithInsecure(),
)
```

**Docker Compose app:** Use `host.docker.internal:4317` instead of `localhost:4317`.

For adding Prometheus scrape targets or Faro (browser RUM), see [docs/extending.md](docs/extending.md).

---

## Kind/Helm Deployment (Advanced)

For learning Kubernetes observability with distributed Mimir.

### Prerequisites

| Tool | Install | Purpose |
|------|---------|---------|
| Docker Desktop | [docker.com](https://www.docker.com/products/docker-desktop/) | Container runtime (allocate 8 GB+ RAM) |
| kind | `brew install kind` | Local Kubernetes clusters |
| kubectl | `brew install kubectl` | Kubernetes CLI |
| helm | `brew install helm` | Kubernetes package manager |

### Quick Start

```bash
make setup          # Create kind cluster, namespace, add Helm repos
make deploy         # Deploy all LGTM components + Alloy
make status         # Check pod health
```

No port-forwarding is needed — kind NodePort mappings expose everything to your Mac automatically.

| Service | URL / Address | Notes |
|---------|--------------|-------|
| Grafana | http://localhost:13000 | Login: `admin` / `watchtower` |
| OTLP gRPC | `localhost:14317` | Send traces/metrics/logs here |
| OTLP HTTP | `localhost:14318` | Alternative OTLP endpoint |

> Ports are remapped from the standard 3000/4317/4318 to avoid conflicts with other local services.

## Architecture

```
Instrumented App
      │
      ▼  OTLP (gRPC or HTTP)
┌──────────┐
│  Alloy   │──── fan-out ────┐
└────┬─────┘                 │
     │ local pipeline        │ sumo pipeline
     ▼                       ▼
┌─────────┐           ┌───────────┐
│  Tempo  │ traces    │ Sumo Logic│
│  Mimir  │ metrics   │  (OTLP)   │
│  Loki   │ logs      └───────────┘
└────┬────┘
     │
     ▼
┌─────────┐
│ Grafana │  Explore + Dashboards
└─────────┘
```

Alloy receives OTLP telemetry once and writes it to two independent pipelines:
- **Local**: Tempo (traces via gRPC), Mimir (metrics via Prometheus remote-write), Loki (logs via Loki push API)
- **Sumo Logic**: All signals via OTLP/HTTP to a hosted collection endpoint

## Sending Test Data

```bash
cd test-data
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python generate.py --endpoint localhost:14317 --rate 10
```

The generator simulates three microservices (api-gateway, order-service, payment-service) producing correlated traces, metrics, and logs. After a few seconds, open Grafana Explore to query each backend.

### Verify data arrived

- **Tempo**: Grafana Explore > Tempo datasource > Search > Run query
- **Mimir**: Grafana Explore > Mimir datasource > query `target_info` or `http_server_request_count_total`
- **Loki**: Grafana Explore > Loki datasource > `{service_name="watchtower-generator"}`

## Make Targets

### Docker Compose

```
make docker-up          Start the Docker Compose stack
make docker-down        Stop the stack
make docker-logs        Tail Alloy logs
make docker-status      Show container status
make docker-clean       Stop and remove all volumes (deletes data)
```

### Kind/Helm

```
make setup              Create kind cluster + namespace + Helm repos
make deploy             Deploy all components (tempo, loki, mimir, grafana, alloy)
make deploy-tempo       Deploy only Tempo
make deploy-loki        Deploy only Loki
make deploy-mimir       Deploy only Mimir
make deploy-grafana     Deploy only Grafana
make deploy-alloy       Deploy only Alloy (recreates ConfigMap + Helm upgrade)
make status             Show pod and service status
make logs               Tail Alloy logs
make port-forward       Manual port-forwarding (fallback if NodePorts fail)
make render             Render all Helm charts to helm/rendered/ for learning
make enable-local-only  Switch Alloy to local-only mode (no Sumo)
make disable-local-only Restore dual-write mode
make teardown           Delete the kind cluster entirely
```

## Project Structure

```
watchtower/
├── docker-compose.yml            # Docker Compose deployment
├── docker/
│   ├── alloy-config.alloy        # Alloy config for Docker (local-only)
│   ├── tempo-config.yaml         # Tempo config
│   ├── loki-config.yaml          # Loki config
│   ├── prometheus.yaml           # Prometheus config
│   └── grafana-datasources.yaml  # Grafana datasource provisioning
├── kind/
│   └── cluster-config.yaml       # kind cluster with NodePort mappings
├── helm/values/
│   ├── tempo.yaml                # Tempo: local trace storage
│   ├── loki.yaml                 # Loki: single-binary, filesystem
│   ├── mimir.yaml                # Mimir: distributed mode, filesystem
│   ├── grafana.yaml              # Grafana: pre-provisioned datasources
│   └── alloy.yaml                # Alloy: external ConfigMap, Sumo env, OTLP ports
├── helm/rendered/                # Output of `make render` (gitignored)
├── alloy/
│   ├── config.alloy              # Dual-write config (local + Sumo)
│   └── config-local-only.alloy   # Local-only config (no Sumo dependency)
├── dashboards/                   # Custom Grafana dashboards (JSON)
├── test-data/
│   ├── generate.py               # Synthetic telemetry generator
│   ├── requirements.txt          # Python OTLP dependencies
│   └── .venv/                    # Python virtualenv (not committed)
├── scripts/
│   ├── setup.sh                  # Cluster bootstrap
│   ├── teardown.sh               # Cluster teardown
│   └── port-forward.sh           # Manual port-forward fallback
├── docs/
│   ├── architecture.md
│   ├── helm-learning-notes.md
│   └── sumo-dual-write.md
├── Makefile                      # All operations
└── watchtower-spec.pdf           # Original project spec
```

## Sumo Logic Dual-Write

The Sumo Logic OTLP endpoint is stored as a Kubernetes secret:

```bash
# View the current secret (already created during initial setup)
kubectl get secret sumo-credentials -n watchtower -o jsonpath='{.data.endpoint}' | base64 -d

# Replace the endpoint
kubectl create secret generic sumo-credentials \
  -n watchtower \
  --from-literal=endpoint='https://your-endpoint-here' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment alloy -n watchtower
```

To disable Sumo and run local-only: `make enable-local-only`
To restore dual-write: `make disable-local-only`

## Alloy Config Switching

Two Alloy configs are provided:

| Config | File | Use when |
|--------|------|----------|
| Dual-write | `alloy/config.alloy` | Default. Sends to local LGTM + Sumo Logic |
| Local-only | `alloy/config-local-only.alloy` | Sumo endpoint unavailable or not needed |

Switching is handled by `make enable-local-only` / `make disable-local-only`, which swap the ConfigMap and restart Alloy.

## Grafana Datasource Cross-References

The Grafana datasources are pre-wired for correlation:

- **Tempo -> Loki**: Click a trace to see correlated logs (filtered by trace ID)
- **Tempo -> Mimir**: Service map and trace-to-metrics linking
- **Loki -> Tempo**: Click a trace ID in a log line to jump to the trace
- **Mimir -> Tempo**: Exemplar links from metrics to traces

## Troubleshooting

**Pods stuck in Pending**: Check node resources with `kubectl describe node`. The kind cluster may need more Docker memory.

**Alloy CrashLoopBackOff**: Check logs with `make logs`. Common causes:
- Missing `sumo-credentials` secret (create it or switch to local-only mode)
- Syntax errors in `alloy/config.alloy`

**No data in Grafana**: Verify the generator is sending to the right port (`localhost:14317`). Check Alloy logs for export errors.

**Mimir 401 errors**: `multitenancy_enabled` must be `false` in `helm/values/mimir.yaml`. Redeploy with `make deploy-mimir`.

**NodePort not reachable**: Run `make port-forward` as a fallback. This uses `kubectl port-forward` instead of kind NodePort mappings.
# watchtower
