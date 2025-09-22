#!/usr/bin/env bash
set -euo pipefail

# start-k3d.sh
# Starts an existing k3d cluster (without recreating it).
#
# Usage:
#   bash scripts/start-k3d.sh [CLUSTER_NAME]
#
# Behavior:
#   - If CLUSTER_NAME is provided as the first argument, that cluster will be started.
#   - Otherwise, it will use the K3D_CLUSTER env var if set.
#   - Otherwise, it defaults to the standard k3d default name: "k3s-default".
#
# Examples:
#   bash scripts/start-k3d.sh                 # starts k3s-default
#   bash scripts/start-k3d.sh my-cluster      # starts my-cluster
#   K3D_CLUSTER=my-cluster bash scripts/start-k3d.sh
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
  echo "[ERROR] k3d cluster '$CLUSTER_NAME' does not exist. Create it first: bash scripts/install-k3d.sh" >&2
  exit 1
fi

echo "[INFO] Starting k3d cluster: $CLUSTER_NAME"
k3d cluster start "$CLUSTER_NAME"

echo "[INFO] Cluster '$CLUSTER_NAME' started."
# Helpful context output
if command_exists kubectl; then
  K3D_CONTEXT="k3d-$CLUSTER_NAME"
  echo "[INFO] Switch kubectl context with: kubectl config use-context $K3D_CONTEXT"
  echo "[INFO] Available contexts:"
  kubectl config get-contexts -o name | sed 's/^/[INFO]   /'
fi
