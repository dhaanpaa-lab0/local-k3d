#!/usr/bin/env bash
set -euo pipefail

# destroy-k3d-cluster.sh
# Destroys a k3d cluster created locally.
#
# Usage:
#   bash scripts/destroy-k3d-cluster.sh [CLUSTER_NAME]
#
# Behavior:
#   - If CLUSTER_NAME is provided as the first argument, that cluster will be deleted.
#   - Otherwise, it will use the K3D_CLUSTER env var if set.
#   - Otherwise, it defaults to the standard k3d default name: "k3s-default".
#
# Examples:
#   bash scripts/destroy-k3d-cluster.sh                 # deletes k3s-default
#   bash scripts/destroy-k3d-cluster.sh my-cluster      # deletes my-cluster
#   K3D_CLUSTER=my-cluster bash scripts/destroy-k3d-cluster.sh
#

command_exists() { command -v "$1" >/dev/null 2>&1; }

if ! command_exists k3d; then
  echo "[ERROR] 'k3d' command not found. Please install k3d first: https://k3d.io/" >&2
  exit 1
fi

CLUSTER_NAME="${1:-${K3D_CLUSTER:-k3s-default}}"

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "[ERROR] Cluster name is empty. Provide a name as an argument or via K3D_CLUSTER env var." >&2
  exit 1
fi

echo "[INFO] Deleting k3d cluster: $CLUSTER_NAME"
# This removes the cluster containers and prunes related kubeconfig entries
k3d cluster delete "$CLUSTER_NAME"

echo "[INFO] Done."