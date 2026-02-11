# Watchtower Architecture

## Overview

Watchtower runs the Grafana LGTM stack on a local kind cluster with Alloy as the telemetry router.

## Components

- **Grafana Alloy** - OTLP receiver, batch processor, dual-write fan-out
- **Tempo** - Distributed trace storage and query
- **Loki** - Log aggregation (single-binary mode)
- **Mimir** - Prometheus-compatible metrics storage (distributed mode)
- **Grafana** - Dashboards and Explore UI with cross-datasource correlation

## Data Flow

```
Instrumented App --> OTLP (gRPC/HTTP) --> Alloy --> Tempo (traces)
                                               --> Loki (logs)
                                               --> Mimir (metrics)
                                               --> Sumo Logic (all, optional)
```

## Networking

- kind NodePort mappings expose services to the host Mac
- Internal K8s service discovery connects components (e.g. `tempo.watchtower.svc.cluster.local`)
- Grafana datasources use internal cluster DNS to reach backends
