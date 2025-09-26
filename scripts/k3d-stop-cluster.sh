#!/usr/bin/env bash
set -euo pipefail

# stop-k3d-cluster.sh
# Stops a running k3d cluster (without deleting it).
#
# Usage:
#   bash scripts/stop-k3d-cluster.sh [CLUSTER_NAME]
#
# Behavior:
#   - If CLUSTER_NAME is provided as the first argument, that cluster will be stopped.
#   - Otherwise, it will use the K3D_CLUSTER env var if set.
#   - Otherwise, it defaults to the standard k3d default name: "k3s-default".
#
# Examples:
#   bash scripts/stop-k3d-cluster.sh                  # stops k3s-default
#   bash scripts/stop-k3d-cluster.sh my-cluster       # stops my-cluster
#   K3D_CLUSTER=my-cluster bash scripts/stop-k3d-cluster.sh
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

# Check if the cluster exists
if ! k3d cluster list | awk 'NR>1 {print $1}' | grep -qx "$CLUSTER_NAME"; then
  echo "[ERROR] k3d cluster '$CLUSTER_NAME' does not exist. Nothing to stop." >&2
  exit 1
fi

echo "[INFO] Stopping k3d cluster: $CLUSTER_NAME"
k3d cluster stop "$CLUSTER_NAME"

echo "[INFO] Cluster '$CLUSTER_NAME' stopped."
