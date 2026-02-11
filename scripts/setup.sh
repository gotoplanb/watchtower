#!/usr/bin/env bash
set -euo pipefail

echo "=== Watchtower Setup ==="

# Check prerequisites
for cmd in docker kind kubectl helm; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd is not installed. Install it with: brew install $cmd"
        exit 1
    fi
done

# Check Docker is running
if ! docker info &>/dev/null; then
    echo "ERROR: Docker is not running. Start Docker Desktop first."
    exit 1
fi

# Create the kind cluster
echo "Creating kind cluster 'watchtower'..."
kind create cluster --config kind/cluster-config.yaml

# Verify cluster
echo "Verifying cluster..."
kubectl cluster-info --context kind-watchtower
kubectl get nodes

# Create namespace
echo "Creating namespace 'watchtower'..."
kubectl create namespace watchtower

# Add Grafana Helm repo
echo "Adding Grafana Helm repository..."
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

echo ""
echo "=== Setup complete ==="
echo "Cluster 'watchtower' is running."
echo "Run 'make deploy' to install the LGTM stack."
