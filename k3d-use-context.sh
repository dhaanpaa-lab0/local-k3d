#!/usr/bin/env bash
# Switch kubectl's default context to the k3d cluster created by this repo
# Usage:
#   bash k3d-use-context.sh [CLUSTER_NAME]
# Defaults to the cluster name used in k3d-create-cluster.sh: lk3d-cluster

set -euo pipefail

CLUSTER_NAME="${1:-lk3d-cluster}"
TARGET_CONTEXT="k3d-${CLUSTER_NAME}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl is not installed or not in PATH" >&2
  exit 1
fi

# Ensure target context exists in kubeconfig
if ! kubectl config get-contexts -o name | grep -qx "${TARGET_CONTEXT}"; then
  echo "Error: kube context '${TARGET_CONTEXT}' not found in your kubeconfig." >&2
  echo "Hint: Make sure the cluster '${CLUSTER_NAME}' exists (e.g., 'k3d cluster list')." >&2
  echo "      If you just created it with k3d, the context should be created automatically." >&2
  exit 1
fi

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
echo "[local-k3d] Current context: ${CURRENT_CONTEXT:-<none>}"
echo "[local-k3d] Switching to context: ${TARGET_CONTEXT}"

kubectl config use-context "${TARGET_CONTEXT}"

NEW_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
echo "[local-k3d] Now using context: ${NEW_CONTEXT}"
