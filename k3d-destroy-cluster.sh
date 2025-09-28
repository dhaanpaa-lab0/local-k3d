#!/usr/bin/env bash
# Destroy a local k3d cluster created by k3d-create-cluster.sh
# Usage:
#   bash k3d-destroy-cluster.sh [CLUSTER_NAME]
# Default cluster name matches k3d-create-cluster.sh: lk3d-cluster

set -euo pipefail

CLUSTER_NAME="${1:-lk3d-cluster}"

echo "[local-k3d] Deleting k3d cluster: ${CLUSTER_NAME}"
if ! command -v k3d >/dev/null 2>&1; then
  echo "Error: k3d is not installed or not in PATH" >&2
  exit 1
fi

# Delete the cluster (removes kubecontext too)
k3d cluster delete "${CLUSTER_NAME}"

echo "[local-k3d] Cluster '${CLUSTER_NAME}' deleted."
