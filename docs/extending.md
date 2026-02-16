# Extending Watchtower

This guide shows how to extend the base Watchtower stack for your specific needs. All examples are for Docker Compose deployment; Kind/Helm users should adapt the concepts to their Helm values.

## Adding Prometheus Scrape Targets

Edit `docker/prometheus.yaml` to add your application's metrics endpoint:

```yaml
scrape_configs:
  # ... existing configs ...

  # Your Django/FastAPI/Node app
  - job_name: 'my-app'
    metrics_path: /metrics
    scrape_interval: 10s
    static_configs:
      - targets:
          - host.docker.internal:8000
        labels:
          app: my-app
          env: dev

  # Multiple environments
  - job_name: 'my-app-staging'
    metrics_path: /metrics
    static_configs:
      - targets:
          - host.docker.internal:8001
        labels:
          app: my-app
          env: staging
```

After editing, restart Prometheus:
```bash
docker-compose restart prometheus
```

## Adding Faro Receiver (Frontend RUM)

To receive telemetry from browser apps using the [Grafana Faro Web SDK](https://grafana.com/docs/grafana-cloud/monitor-applications/frontend-observability/):

### 1. Update docker-compose.yml

Add the Faro port to the Alloy service:

```yaml
alloy:
  ports:
    - "4317:4317"   # OTLP gRPC
    - "4318:4318"   # OTLP HTTP
    - "12345:12345" # Alloy UI
    - "12347:12347" # Faro receiver  # ADD THIS
```

### 2. Update docker/alloy-config.alloy

Add the Faro receiver block:

```alloy
// =============================================================================
// FARO RECEIVER - Browser telemetry from Faro Web SDK
// =============================================================================

faro.receiver "default" {
  server {
    listen_address = "0.0.0.0"
    listen_port = 12347
    cors_allowed_origins = ["*"]  // Restrict in production!
    max_allowed_payload_size = "5MiB"

    rate_limiting {
      enabled = true
      rate = 50
      burst_size = 100
    }
  }

  output {
    logs   = [loki.write.local.receiver]
    traces = [otelcol.exporter.otlp.tempo.input]
  }
}
```

### 3. Configure your frontend

```javascript
import { initializeFaro } from '@grafana/faro-web-sdk';

initializeFaro({
  url: 'http://localhost:12347/collect',
  app: {
    name: 'my-frontend',
    version: '1.0.0',
  },
});
```

## Adding Cloud Dual-Write

To send telemetry to both local backends AND a cloud provider (Grafana Cloud, Sumo Logic, etc.):

### Grafana Cloud

Add to `docker/alloy-config.alloy`:

```alloy
// =============================================================================
// GRAFANA CLOUD AUTHENTICATION
// =============================================================================

otelcol.auth.basic "grafana_cloud" {
  username = env("GRAFANA_CLOUD_INSTANCE_ID")
  password = env("GRAFANA_CLOUD_API_TOKEN")
}

// =============================================================================
// GRAFANA CLOUD EXPORTERS
// =============================================================================

// Traces to Grafana Cloud Tempo
otelcol.exporter.otlphttp "grafana_cloud_traces" {
  client {
    endpoint = env("GRAFANA_CLOUD_OTLP_ENDPOINT")
    auth     = otelcol.auth.basic.grafana_cloud.handler
  }
}

// Logs to Grafana Cloud Loki
otelcol.exporter.otlphttp "grafana_cloud_logs" {
  client {
    endpoint = env("GRAFANA_CLOUD_OTLP_ENDPOINT")
    auth     = otelcol.auth.basic.grafana_cloud.handler
  }
}

// Metrics to Grafana Cloud Prometheus
prometheus.remote_write "grafana_cloud" {
  endpoint {
    url = env("GRAFANA_CLOUD_PROMETHEUS_URL")
    basic_auth {
      username = env("GRAFANA_CLOUD_PROMETHEUS_USER")
      password = env("GRAFANA_CLOUD_PROMETHEUS_API_TOKEN")
    }
  }
}
```

Update the batch processor to fan out to both local and cloud:

```alloy
otelcol.processor.batch "default" {
  timeout         = "5s"
  send_batch_size = 1000

  output {
    traces  = [
      otelcol.exporter.otlp.tempo.input,
      otelcol.exporter.otlphttp.grafana_cloud_traces.input,
    ]
    metrics = [otelcol.exporter.prometheus.local.input]
    logs    = [
      otelcol.exporter.loki.local.input,
      otelcol.exporter.otlphttp.grafana_cloud_logs.input,
    ]
  }
}
```

Update the Prometheus exporter to dual-write:

```alloy
otelcol.exporter.prometheus "local" {
  forward_to = [
    prometheus.remote_write.local.receiver,
    prometheus.remote_write.grafana_cloud.receiver,
  ]
}
```

### Environment Variables

Create a `.env` file in the watchtower root:

```bash
# Grafana Cloud credentials
GRAFANA_CLOUD_INSTANCE_ID=123456
GRAFANA_CLOUD_API_TOKEN=glc_xxx...
GRAFANA_CLOUD_OTLP_ENDPOINT=https://otlp-gateway-prod-us-central-0.grafana.net/otlp
GRAFANA_CLOUD_PROMETHEUS_URL=https://prometheus-prod-us-central-0.grafana.net/api/prom/push
GRAFANA_CLOUD_PROMETHEUS_USER=123456
GRAFANA_CLOUD_PROMETHEUS_API_TOKEN=glc_xxx...
```

Update `docker-compose.yml` to load the env file:

```yaml
alloy:
  env_file:
    - .env
```

### Sumo Logic

For Sumo Logic OTLP endpoint:

```alloy
otelcol.exporter.otlphttp "sumo" {
  client {
    endpoint = env("SUMO_OTLP_ENDPOINT")
    // No auth needed - endpoint URL contains the token
  }
}
```

## Adding Custom Dashboards

Place JSON dashboard files in a `dashboards/` directory and mount them in Grafana:

```yaml
grafana:
  volumes:
    - ./docker/grafana-datasources.yaml:/etc/grafana/provisioning/datasources/datasources.yaml:ro
    - ./dashboards:/etc/grafana/provisioning/dashboards/json:ro
    - ./docker/grafana-dashboards.yaml:/etc/grafana/provisioning/dashboards/dashboards.yaml:ro
```

Create `docker/grafana-dashboards.yaml`:

```yaml
apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /etc/grafana/provisioning/dashboards/json
```

## Switching Between Prometheus and Mimir

The Docker Compose setup uses Prometheus for simplicity. To use Mimir instead (for learning distributed metrics):

1. Replace the `prometheus` service with `mimir` in `docker-compose.yml`
2. Update the Alloy config to write to Mimir's distributor endpoint
3. Update Grafana datasources to point to Mimir

See the Kind/Helm deployment for a working Mimir configuration.
