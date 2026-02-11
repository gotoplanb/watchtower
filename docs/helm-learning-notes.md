# Helm Learning Notes

## What Helm Does

Helm charts are templated Kubernetes manifests. `helm install` renders templates with your values and applies the resulting YAML to the cluster.

## Key Concepts

- **Chart** - A package of K8s resource templates
- **Release** - A deployed instance of a chart
- **Values** - Configuration overrides passed via `-f values.yaml`
- **`helm template`** - Renders manifests locally without deploying (use `make render`)

## What Each Chart Creates

### Tempo
StatefulSet + PVC for trace storage, Service for discovery, ConfigMap for Tempo config.

### Loki
Supports single-binary, simple-scalable, and microservices modes. We use single-binary.

### Mimir (mimir-distributed)
Even at 1 replica each, creates: distributor, ingester, querier, query-frontend, store-gateway, compactor as separate Deployments/StatefulSets.

### Grafana
Deployment + Service + ConfigMap with provisioned datasources.

### Alloy
Deployment (or DaemonSet) + Service. Config is managed via a separate ConfigMap.

## Useful Commands

```bash
helm template <release> <chart> -f values.yaml  # See raw manifests
helm get values <release> -n watchtower          # See applied values
helm history <release> -n watchtower             # See release history
helm uninstall <release> -n watchtower           # Remove a release
```
