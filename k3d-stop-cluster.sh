#!/usr/bin/env bash
# Stop a running local k3d cluster without deleting it
# Usage:
#   bash k3d-stop-cluster.sh [CLUSTER_NAME]
# Default cluster name matches k3d-create-cluster.sh: lk3d-cluster

set -euo pipefail

CLUSTER_NAME="${1:-lk3d-cluster}"

echo "[local-k3d] Stopping k3d cluster: ${CLUSTER_NAME}"
if ! command -v k3d >/dev/null 2>&1; then
  echo "Error: k3d is not installed or not in PATH" >&2
  exit 1
fi

# Stop the cluster
k3d cluster stop "${CLUSTER_NAME}"

echo "[local-k3d] Cluster '${CLUSTER_NAME}' stopped."