#!/usr/bin/env bash
set -euo pipefail

# submit-hello-world.sh
# Uses the previously created Argo admin ServiceAccount to authenticate to argo-server
# and submits the official hello-world workflow to a local k3d/k3s Argo Workflows install.
#
# Behavior:
# - Detects a k3d kube-context automatically (override with K3D_CONTEXT)
# - Uses namespace "argo" by default (override with ARGO_NS)
# - Uses ServiceAccount name "argo-admin" by default (override with SA_NAME)
# - Prefers submitting via the Argo Server over HTTP using Traefik ingress if present
#   (host/port configurable via ARGO_INGRESS_HOST + K3D_HTTP_PORT). If no ingress is found,
#   falls back to a temporary port-forward to localhost:2746.
# - Obtains a short-lived bearer token for the ServiceAccount (24h) using kubectl; falls back
#   to a token secret if necessary, similar to scripts/config-argo-adm-acct.sh
#
# Requirements:
# - argo CLI installed. If missing, run: bash scripts/install-argo.sh
# - kubectl configured to access your k3d cluster
#
# Usage:
#   bash scripts/submit-hello-world.sh
#   K3D_CONTEXT=k3d-k3s-default ARGO_NS=argo SA_NAME=argo-admin bash scripts/submit-hello-world.sh
#   ARGO_INGRESS_HOST=argo.localtest.me K3D_HTTP_PORT=8281 bash scripts/submit-hello-world.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Config
ARGO_NS="${ARGO_NS:-argo}"
SA_NAME="${SA_NAME:-argo-admin}"
K3D_CONTEXT="${K3D_CONTEXT:-}"
K3D_HTTP_PORT="${K3D_HTTP_PORT:-8281}"
ARGO_INGRESS_HOST="${ARGO_INGRESS_HOST:-argo.localtest.me}"
ARGO_VERSION_PIN="${ARGO_VERSION:-v3.5.8}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

choose_k3d_context() {
  local desired_ctx="${1:-}"
  if [[ -n "$desired_ctx" ]]; then
    echo "$desired_ctx"; return 0
  fi
  local current
  current=$(kubectl config current-context 2>/dev/null || true)
  if [[ "$current" == k3d-* ]]; then echo "$current"; return 0; fi
  if kubectl config get-contexts -o name | grep -q '^k3d-k3s-default$'; then
    echo "k3d-k3s-default"; return 0
  fi
  local k3d_contexts=()
  while IFS= read -r ctx; do
    [[ -n "$ctx" ]] && k3d_contexts+=("$ctx")
  done < <(kubectl config get-contexts -o name | grep '^k3d-' || true)
  if [[ ${#k3d_contexts[@]} -eq 1 ]]; then echo "${k3d_contexts[0]}"; return 0; fi
  echo ""
}

# Preconditions
for bin in kubectl argo; do
  if ! command_exists "$bin"; then
    if [[ "$bin" == "argo" ]]; then
      echo "[ERROR] 'argo' CLI not found. Install it with: bash scripts/install-argo.sh" >&2
    else
      echo "[ERROR] '$bin' is required but not found in PATH." >&2
    fi
    exit 1
  fi
done

KUBE_CONTEXT=$(choose_k3d_context "$K3D_CONTEXT")
if [[ -z "$KUBE_CONTEXT" ]]; then
  echo "[ERROR] Could not determine a unique k3d Kubernetes context." >&2
  echo "        - Ensure your k3d cluster exists (bash scripts/install-k3d.sh)." >&2
  echo "        - Or set K3D_CONTEXT explicitly (e.g., export K3D_CONTEXT=k3d-k3s-default)." >&2
  exit 1
fi

echo "[INFO] Using kube-context: $KUBE_CONTEXT"
kubectl config use-context "$KUBE_CONTEXT" >/dev/null

# Ensure namespace exists
if ! kubectl get ns "$ARGO_NS" >/dev/null 2>&1; then
  echo "[ERROR] Namespace '$ARGO_NS' not found. Install Argo first: bash scripts/install-argo.sh" >&2
  exit 1
fi

# Ensure ServiceAccount exists
if ! kubectl -n "$ARGO_NS" get sa "$SA_NAME" >/dev/null 2>&1; then
  echo "[ERROR] ServiceAccount '$SA_NAME' not found in namespace '$ARGO_NS'. Create it: bash scripts/setup-argo-admin.sh" >&2
  exit 1
fi

# Get SA token (prefer kubectl create token)
TOKEN=""
set +e
TOKEN=$(kubectl -n "$ARGO_NS" create token "$SA_NAME" --duration=24h 2>/dev/null)
KCTL_CREATE_TOKEN_RC=$?
set -e
if [[ $KCTL_CREATE_TOKEN_RC -ne 0 || -z "$TOKEN" ]]; then
  echo "[WARN] 'kubectl create token' failed or unavailable. Falling back to secret-based token retrieval."
  SECRET_NAME="${SA_NAME}-token"
  if ! kubectl -n "$ARGO_NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    kubectl -n "$ARGO_NS" create secret generic "$SECRET_NAME" \
      --type=kubernetes.io/service-account-token \
      --from-literal=placeholder=dummy >/dev/null 2>&1 || true
    kubectl -n "$ARGO_NS" patch secret "$SECRET_NAME" -p "{\"metadata\":{\"annotations\":{\"kubernetes.io/service-account.name\":\"$SA_NAME\"}}}" >/dev/null
    echo "[INFO] Waiting for token controller to populate the secret..."
    sleep 2
  fi
  TOKEN=$(kubectl -n "$ARGO_NS" get secret "$SECRET_NAME" -o jsonpath='{.data.token}' | base64 --decode || true)
fi

if [[ -z "$TOKEN" ]]; then
  echo "[ERROR] Failed to obtain a token for ServiceAccount '$SA_NAME' in namespace '$ARGO_NS'." >&2
  exit 1
fi

echo "[INFO] Obtained token for SA '$SA_NAME'."

# Determine server endpoint: prefer ingress, else port-forward
USE_PORT_FORWARD="false"
SERVER_HOST="$ARGO_INGRESS_HOST"
SERVER_PORT="$K3D_HTTP_PORT"

if kubectl -n "$ARGO_NS" get ingressroute.traefik.io argo-server >/dev/null 2>&1 || \
   kubectl -n "$ARGO_NS" get ingress argo-server >/dev/null 2>&1; then
  echo "[INFO] Using ingress endpoint: http://$SERVER_HOST:$SERVER_PORT"
else
  echo "[INFO] No ingress found for argo-server. Using temporary port-forward to localhost:2746"
  USE_PORT_FORWARD="true"
  SERVER_HOST="localhost"
  SERVER_PORT="2746"
fi

PF_PID=""
cleanup() {
  if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" >/dev/null 2>&1; then
    echo "[INFO] Stopping port-forward (pid=$PF_PID)"
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "$USE_PORT_FORWARD" == "true" ]]; then
  kubectl -n "$ARGO_NS" port-forward svc/argo-server 2746:2746 >/dev/null 2>&1 &
  PF_PID=$!
  # Wait for port to be ready
  for i in {1..30}; do
    if nc -z "$SERVER_HOST" "$SERVER_PORT" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if ! nc -z "$SERVER_HOST" "$SERVER_PORT" >/dev/null 2>&1; then
    echo "[ERROR] Failed to establish port-forward to argo-server on $SERVER_HOST:$SERVER_PORT" >&2
    exit 1
  fi
  echo "[INFO] Port-forward established (pid=$PF_PID)."
fi

# Submit directly with bearer token (no `argo login` required for compatibility across CLI versions)
# Workflow example URL (version-pinned)
WORKFLOW_URL="https://raw.githubusercontent.com/argoproj/argo-workflows/${ARGO_VERSION_PIN}/examples/hello-world.yaml"

ARGO_ADDR="$SERVER_HOST:$SERVER_PORT"
HELPOUT=$(argo submit --help 2>/dev/null || true)
if echo "$HELPOUT" | grep -q -- "--auth-mode"; then
  echo "[INFO] Detected argo CLI supports server auth flags; submitting via argo-server at $ARGO_ADDR using bearer token"
  set +e
  argo submit --watch \
    "$WORKFLOW_URL" \
    -n "$ARGO_NS" \
    --serviceaccount "$SA_NAME" \
    --server "$ARGO_ADDR" \
    --auth-mode bearer \
    --token "$TOKEN" \
    --insecure
  RC=$?
  set -e
else
  echo "[WARN] Your 'argo' CLI does not support '--auth-mode/--server' flags. Falling back to direct submit via kubeconfig."
  echo "[INFO] Submitting hello-world workflow directly to the Kubernetes API in namespace '$ARGO_NS' using ServiceAccount '$SA_NAME'"
  set +e
  argo submit --watch \
    "$WORKFLOW_URL" \
    -n "$ARGO_NS" \
    --serviceaccount "$SA_NAME"
  RC=$?
  set -e
  if [[ $RC -ne 0 ]]; then
    echo "[WARN] 'argo submit' direct mode failed (exit code $RC). Falling back to 'kubectl create -f' with serviceAccount injection."
    # Download to temp and inject spec.serviceAccountName if not present
    TMP_YAML="$(mktemp)"
    if ! curl -fsSL "$WORKFLOW_URL" -o "$TMP_YAML"; then
      echo "[ERROR] Failed to download workflow YAML from $WORKFLOW_URL" >&2
      RC=$RC
    else
      if ! grep -qE '^\s*serviceAccountName:' "$TMP_YAML"; then
        # Insert serviceAccountName under top-level spec:
        awk -v sa="$SA_NAME" '
          BEGIN{inSpec=0}
          /^spec:\s*$/{print; print "  serviceAccountName: " sa; inSpec=1; next}
          {print}
        ' "$TMP_YAML" > "$TMP_YAML.inj" && mv "$TMP_YAML.inj" "$TMP_YAML"
      fi
      set +e
      kubectl -n "$ARGO_NS" create -f "$TMP_YAML"
      RC=$?
      set -e
      rm -f "$TMP_YAML" 2>/dev/null || true
    fi
  fi
fi

if [[ $RC -ne 0 ]]; then
  echo "[ERROR] Workflow submission failed (exit code $RC)." >&2
  exit $RC
fi

echo "[SUCCESS] hello-world workflow submitted and completed (or is being watched) in namespace '$ARGO_NS'."
if [[ "$USE_PORT_FORWARD" == "true" ]]; then
  echo "[INFO] You can also open the UI at: http://localhost:2746"
else
  echo "[INFO] You can view it in the UI: http://$SERVER_HOST:$SERVER_PORT"
fi
