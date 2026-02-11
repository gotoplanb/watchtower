# Sumo Logic Dual-Write Pattern

## How It Works

Alloy's OTLP receiver fans out telemetry to two independent pipelines:

1. **Local pipeline** - batch processor -> Tempo/Loki/Mimir exporters
2. **Sumo pipeline** - batch processor -> Sumo Logic OTLP HTTP exporter

The fan-out happens at the receiver output level. Each pipeline has its own batch processor and exporter, so backpressure is handled independently. If Sumo is slow, the local pipeline is unaffected.

## Configuration

The Sumo endpoint is stored as a Kubernetes Secret and injected via environment variable:

```bash
kubectl create secret generic sumo-credentials \
    -n watchtower \
    --from-literal=endpoint=https://your-sumo-otlp-endpoint.sumologic.com/...
```

## Switching Modes

```bash
make enable-local-only   # Remove Sumo pipeline, local LGTM only
make disable-local-only  # Restore dual-write (LGTM + Sumo)
```

## Why This Pattern

- Evaluate Grafana tooling against real telemetry without disrupting production Sumo pipeline
- Adding new export destinations is a config change, not an architecture change
- Independent backpressure means one slow destination doesn't affect others
