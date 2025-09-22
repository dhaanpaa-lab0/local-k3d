#!/usr/bin/env bash
set -euo pipefail

# setup-argo-ingress.sh
# Sets up an Ingress for the Argo Workflows UI (argo-server) on a local k3d/k3s cluster.
# - Applies the manifest at k8s/argo-ui-ingress.yaml by default.
# - Ensures the "argo" namespace exists (configurable via ARGO_NS).
# - Optionally overrides the Ingress host via ARGO_INGRESS_HOST.
# - Selects a k3d kube-context similar to scripts/install-argo.sh (override with K3D_CONTEXT).
# - Prints the URL (http) to access the UI via Traefik on host port ${K3D_HTTP_PORT:-8281}.
#
# Environment variables:
#   K3D_CONTEXT         Override kube context to use. Default: auto-detect k3d context.
#   ARGO_NS             Namespace to use. Default: argo
#   ARGO_INGRESS_FILE   Path to ingress manifest. Default: k8s/argo-ui-ingress.yaml
#   ARGO_INGRESS_HOST   Host to use in the Ingress (overrides manifest). Example: argo.localtest.me
#   K3D_HTTP_PORT       Host port forwarded to Traefik HTTP entrypoint (LB 80). Default: 8281
#
# Usage:
#   bash scripts/setup-argo-ingress.sh
#   ARGO_INGRESS_HOST=argo.dev.localtest.me bash scripts/setup-argo-ingress.sh
#   K3D_CONTEXT=k3d-k3s-default ARGO_NS=argo bash scripts/setup-argo-ingress.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ARGO_NS="${ARGO_NS:-argo}"
K3D_CONTEXT="${K3D_CONTEXT:-}"
K3D_HTTP_PORT="${K3D_HTTP_PORT:-8281}"
ARGO_INGRESS_FILE="${ARGO_INGRESS_FILE:-$REPO_ROOT/k8s/argo-ui-ingress.yaml}"
ARGO_INGRESS_HOST="${ARGO_INGRESS_HOST:-}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

choose_k3d_context() {
  local desired_ctx="$1"
  if [[ -n "$desired_ctx" ]]; then
    echo "$desired_ctx"
    return 0
  fi

  local current
  current=$(kubectl config current-context 2>/dev/null || true)
  if [[ "$current" == k3d-* ]]; then
    echo "$current"
    return 0
  fi

  if kubectl config get-contexts -o name | grep -q '^k3d-k3s-default$'; then
    echo "k3d-k3s-default"
    return 0
  fi

  local k3d_contexts
  k3d_contexts=()
  while IFS= read -r ctx; do
    [[ -n "$ctx" ]] && k3d_contexts+=("$ctx")
  done < <(kubectl config get-contexts -o name | grep '^k3d-' || true)
  if [[ ${#k3d_contexts[@]} -eq 1 ]]; then
    echo "${k3d_contexts[0]}"
    return 0
  fi

  echo "" # not found or ambiguous
}

echo "[INFO] Verifying prerequisites..."
for bin in kubectl; do
  if ! command_exists "$bin"; then
    echo "[ERROR] '$bin' is required but not found in PATH." >&2
    exit 1
  fi
done

KUBE_CONTEXT=$(choose_k3d_context "$K3D_CONTEXT")
if [[ -z "$KUBE_CONTEXT" ]]; then
  echo "[ERROR] Could not determine a unique k3d Kubernetes context."
  echo "        - Ensure your k3d cluster is created (e.g., 'bash scripts/install-k3d.sh')."
  echo "        - Or set K3D_CONTEXT explicitly (e.g., 'export K3D_CONTEXT=k3d-k3s-default')."
  exit 1
fi

echo "[INFO] Using kube-context: $KUBE_CONTEXT"
kubectl config use-context "$KUBE_CONTEXT" >/dev/null

# Ensure namespace exists
if kubectl get ns "$ARGO_NS" >/dev/null 2>&1; then
  echo "[INFO] Namespace '$ARGO_NS' already exists."
else
  echo "[INFO] Creating namespace: $ARGO_NS"
  kubectl create namespace "$ARGO_NS"
fi

# Prepare manifest (optionally override host)
MANIFEST_TO_APPLY="$ARGO_INGRESS_FILE"
TMP_FILE=""
if [[ -n "$ARGO_INGRESS_HOST" ]]; then
  echo "[INFO] Overriding ingress host to: $ARGO_INGRESS_HOST"
  TMP_FILE="$(mktemp)"
  # Replace Host(`...`) in IngressRoute if present; also handle legacy Ingress 'host:' key
  sed -E 's/Host(`[^)]*`)/Host(`"$ARGO_INGRESS_HOST"`)/; 0,/^  - host:/ s/^  - host: .*/  - host: '"$ARGO_INGRESS_HOST"'/' \
    "$ARGO_INGRESS_FILE" > "$TMP_FILE"
  MANIFEST_TO_APPLY="$TMP_FILE"
fi

echo "[INFO] Applying ingress manifest: $MANIFEST_TO_APPLY"
kubectl apply -f "$MANIFEST_TO_APPLY"

# Cleanup temp file if created
if [[ -n "${TMP_FILE}" ]]; then
  rm -f "$TMP_FILE"
fi

# Basic checks and hints
if ! kubectl -n "$ARGO_NS" get svc argo-server >/dev/null 2>&1; then
  echo "[WARN] 'argo-server' Service not found in namespace '$ARGO_NS'."
  echo "[WARN] You may need to install Argo Workflows first: bash scripts/install-argo.sh"
fi

HOST_TO_PRINT="${ARGO_INGRESS_HOST:-argo.localtest.me}"
if kubectl -n "$ARGO_NS" get ingressroute.traefik.io argo-server >/dev/null 2>&1 || \
   kubectl -n "$ARGO_NS" get ingress argo-server >/dev/null 2>&1; then
  echo "[INFO] Ingress(Route) 'argo-server' is configured in namespace '$ARGO_NS'."
  echo "[INFO] Open: http://${HOST_TO_PRINT}:${K3D_HTTP_PORT}"
else
  echo "[ERROR] Failed to create Ingress or IngressRoute 'argo-server' in namespace '$ARGO_NS'."
  exit 1
fi

echo "[INFO] Done."