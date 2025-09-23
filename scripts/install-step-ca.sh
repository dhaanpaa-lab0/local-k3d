#!/usr/bin/env bash
set -euo pipefail

# install-step-ca.sh
# Installs Smallstep step-ca and step-issuer via Helm, then applies the StepClusterIssuer.
# The StepClusterIssuer manifest is expected at k8s/step-cluster-issuer.yaml and must
# be edited to include your step-ca root CA (caBundle) and provisioner password.
#
# Usage:
#   bash scripts/install-step-ca.sh
# Env:
#   K3D_CONTEXT   Optional kube context to use (auto-detects a k3d context by default)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ISSUER_FILE="$REPO_ROOT/k8s/step-cluster-issuer.yaml"

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

# Helm repos
helm repo add smallstep https://smallstep.github.io/helm-charts >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null || true
helm repo update >/dev/null

# Install step-ca
STEP_NS=step-system
echo "[INFO] Installing/Upgrading step-certificates (step-ca) in namespace '$STEP_NS'..."
helm upgrade --install step-ca smallstep/step-certificates \
  --namespace "$STEP_NS" --create-namespace

echo "[INFO] Waiting for step-certificates to be Ready..."
kubectl -n "$STEP_NS" rollout status deploy/step-certificates --timeout=180s || true

# Install step-issuer
echo "[INFO] Installing/Upgrading step-issuer in namespace 'cert-manager'..."
helm upgrade --install step-issuer smallstep/step-issuer \
  --namespace cert-manager --create-namespace

echo "[DONE] step-ca, step-issuer installed, and StepClusterIssuer applied (if populated)."
