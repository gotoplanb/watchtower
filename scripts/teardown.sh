#!/usr/bin/env bash
set -euo pipefail

echo "=== Watchtower Teardown ==="
echo "Deleting kind cluster 'watchtower'..."
kind delete cluster --name watchtower
echo "Cluster deleted."
