#!/usr/bin/env bash
set -euo pipefail

# setup-zitadel.sh
# Installs CloudNativePG operator, creates a Postgres cluster, requests a TLS certificate
# via cert-manager/step-issuer, and deploys ZITADEL via Helm with provided values.
#
# Prerequisites:
#  - A k3d cluster created (see scripts/install-k3d.sh)
#  - cert-manager installed (scripts/install-cert-manager.sh)
#  - step-ca and step-issuer installed, and StepClusterIssuer applied
#    (scripts/install-step-ca.sh with k8s/step-cluster-issuer.yaml filled in)
#
# Usage:
#   bash scripts/setup-zitadel.sh
# Env:
#   K3D_CONTEXT          Optional kube context to use
#   ZITA_NS              Namespace for ZITADEL (default: zitadel)
#   CNPG_NS              Namespace for CNPG operator (default: cnpg-system)
#   ZITA_HOST            External host (default: zita.localtest.me)
#   ZITA_VALUES_FILE     Path to values (default: k8s/zitadel-values.yaml)
#   APPLY_CERT           If set to 'false', skip applying k8s/zita-cert.yaml (default: true)
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

K3D_CONTEXT="${K3D_CONTEXT:-}"
ZITA_NS="${ZITA_NS:-zitadel}"
CNPG_NS="${CNPG_NS:-cnpg-system}"
ZITA_HOST="${ZITA_HOST:-zita.localtest.me}"
ZITA_VALUES_FILE="${ZITA_VALUES_FILE:-$REPO_ROOT/k8s/zitadel-values.yaml}"
APPLY_CERT="${APPLY_CERT:-true}"

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

# Prepare namespaces
kubectl get ns "$ZITA_NS" >/dev/null 2>&1 || kubectl create ns "$ZITA_NS"

# Helm repos
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
helm repo add zitadel https://charts.zitadel.com >/dev/null
helm repo update >/dev/null

# Install CNPG operator
if ! kubectl get ns "$CNPG_NS" >/dev/null 2>&1; then kubectl create ns "$CNPG_NS"; fi

echo "[INFO] Installing/Upgrading CloudNativePG operator in '$CNPG_NS'..."
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace "$CNPG_NS"

# Apply Postgres cluster and secrets
echo "[INFO] Applying Postgres Cluster and Secrets..."
kubectl apply -f "$REPO_ROOT/k8s/pg-zita.yaml"

echo "[INFO] Waiting for CNPG cluster 'pg-zita' to be Ready (this can take a minute)..."
kubectl -n "$ZITA_NS" wait cluster/pg-zita --for=condition=Ready --timeout=180s || true

# Apply cert if requested
if [[ "$APPLY_CERT" == "true" ]]; then
  echo "[INFO] Applying Certificate manifest for host $ZITA_HOST ..."
  # Ensure the certificate file has the desired host; warn if different
  if ! grep -q "$ZITA_HOST" "$REPO_ROOT/k8s/zita-cert.yaml"; then
    echo "[WARN] k8s/zita-cert.yaml dnsNames does not match ZITA_HOST=$ZITA_HOST. Edit the file if needed."
  fi
  kubectl apply -f "$REPO_ROOT/k8s/zita-cert.yaml"
fi

# Install ZITADEL via Helm
if [[ ! -f "$ZITA_VALUES_FILE" ]]; then
  echo "[ERROR] Values file not found: $ZITA_VALUES_FILE" >&2
  exit 1
fi

if grep -q "REPLACE_WITH_" "$ZITA_VALUES_FILE"; then
  echo "[WARN] ZITADEL values file contains placeholders (masterkey, etc). Please edit $ZITA_VALUES_FILE before proceeding."
  echo "[INFO] Proceeding with Helm install anyway (for dev)."
fi

echo "[INFO] Installing/Upgrading ZITADEL in namespace '$ZITA_NS'..."
helm upgrade --install zitadel zitadel/zitadel \
  --namespace "$ZITA_NS" \
  --values "$ZITA_VALUES_FILE"

echo "[INFO] Waiting for ZITADEL deployment to roll out (up to 5m)..."
kubectl -n "$ZITA_NS" rollout status deploy -l app.kubernetes.io/name=zitadel --timeout=5m || true

echo "[DONE] ZITADEL setup complete."
echo "[INFO] Open: https://$ZITA_HOST"
