#!/usr/bin/env bash
set -euo pipefail

# Port-forward Grafana, OTLP gRPC, and OTLP HTTP.
# Uses NodePort mappings defined in kind/cluster-config.yaml, so port-forwarding
# is only needed if NodePort isn't working or you prefer explicit forwards.

cleanup() {
    echo ""
    echo "Stopping port-forwards..."
    kill $(jobs -p) 2>/dev/null || true
    exit 0
}
trap cleanup SIGINT SIGTERM

echo "Starting port-forwards..."
echo "  Grafana:   http://localhost:13000 (admin / watchtower)"
echo "  OTLP gRPC: localhost:14317"
echo "  OTLP HTTP: localhost:14318"
echo ""
echo "Press Ctrl+C to stop all port-forwards."
echo ""

# Grafana
kubectl port-forward -n watchtower svc/grafana 13000:80 &

# Alloy OTLP gRPC
kubectl port-forward -n watchtower svc/alloy 14317:4317 &

# Alloy OTLP HTTP
kubectl port-forward -n watchtower svc/alloy 14318:4318 &

wait
