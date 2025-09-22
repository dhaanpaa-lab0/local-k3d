#!/usr/bin/env bash
set -euo pipefail

# install-cert-manager.sh
# Installs cert-manager via Helm with CRDs enabled into cert-manager namespace.
# Usage:
#   bash scripts/install-cert-manager.sh
# Env:
#   K3D_CONTEXT   Optional kube context to use (auto-detects a k3d context by default)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

command_exists() { command -v "$1" >/dev/null 2>&1; }

choose_k3d_context() {
  local desired_ctx="${1:-}"
  if [[ -n "$desired_ctx" ]]; then echo "$desired_ctx"; return 0; fi
  local current
  current=$(kubectl config current-context 2>/dev/null || true)
  if [[ "$current" == k3d-* ]]; then echo "$current"; return 0; fi
  if kubectl config get-contexts -o name | grep -q '^k3d-k3s-default$'; then
    echo "k3d-k3s-default"; return 0
  fi
  local k3d_contexts=()
  while IFS= read -r ctx; do [[ -n "$ctx" ]] && k3d_contexts+=("$ctx"); done < <(kubectl config get-contexts -o name | grep '^k3d-' || true)
  if [[ ${#k3d_contexts[@]} -eq 1 ]]; then echo "${k3d_contexts[0]}"; return 0; fi
  echo ""
}

: "${KUBECONFIG:=}"
K3D_CONTEXT="${K3D_CONTEXT:-}"

if ! command_exists helm; then
  echo "[ERROR] helm is required. Install Helm first: https://helm.sh/docs/intro/install/" >&2
  exit 1
fi
if ! command_exists kubectl; then
  echo "[ERROR] kubectl is required in PATH." >&2
  exit 1
fi

CTX=$(choose_k3d_context "$K3D_CONTEXT")
if [[ -n "$CTX" ]]; then
  echo "[INFO] Using kube-context: $CTX"
  kubectl config use-context "$CTX" >/dev/null
else
  echo "[WARN] No k3d context auto-detected; using current kubectl context."
fi

NS=cert-manager

echo "[INFO] Adding Helm repo jetstack..."
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo update >/dev/null

echo "[INFO] Installing/Upgrading cert-manager in namespace '$NS'..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace "$NS" --create-namespace \
  --set crds.enabled=true

echo "[INFO] Waiting for cert-manager webhook to be Ready..."
kubectl -n "$NS" rollout status deploy/cert-manager-webhook --timeout=120s

echo "[DONE] cert-manager installed."
