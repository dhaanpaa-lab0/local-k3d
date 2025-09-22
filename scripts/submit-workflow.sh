#!/usr/bin/env bash
set -euo pipefail

# submit-workflow.sh
# Generic workflow submitter that uses the created Argo admin ServiceAccount to authenticate
# and submit any Workflow/WorkflowTemplate from a local file path or URL.
#
# Behavior:
# - Auto-detects a k3d kube-context (override with K3D_CONTEXT)
# - Uses namespace "argo" by default (override with ARGO_NS)
# - Uses ServiceAccount name "argo-admin" by default (override with SA_NAME)
# - Prefers submitting via argo-server (through Traefik ingress http://<host>:<port>) if present;
#   otherwise falls back to a temporary port-forward to localhost:2746
# - Obtains a short-lived bearer token for the SA (24h) using kubectl; falls back to token Secret
# - Ensures the submitted workflow runs under the desired ServiceAccount by passing
#   --serviceaccount where supported, or injecting spec.serviceAccountName for kubectl fallback
#
# Requirements:
# - argo CLI and kubectl installed
#
# Usage:
#   bash scripts/submit-workflow.sh <FILE_OR_URL> [--watch]
#   Examples:
#     bash scripts/submit-workflow.sh ./my-flow.yaml --watch
#     bash scripts/submit-workflow.sh https://example.com/flow.yaml
#   Env overrides:
#     K3D_CONTEXT, ARGO_NS, SA_NAME, ARGO_INGRESS_HOST, K3D_HTTP_PORT, ARGO_VERSION
#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ARGO_NS="${ARGO_NS:-argo}"
SA_NAME="${SA_NAME:-argo-admin}"
K3D_CONTEXT="${K3D_CONTEXT:-}"
K3D_HTTP_PORT="${K3D_HTTP_PORT:-8281}"
ARGO_INGRESS_HOST="${ARGO_INGRESS_HOST:-argo.localtest.me}"
ARGO_VERSION_PIN="${ARGO_VERSION:-v3.5.8}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

choose_k3d_context() {
  local desired_ctx="${1:-}"
  if [[ -n "$desired_ctx" ]]; then echo "$desired_ctx"; return 0; fi
  local current
  current=$(kubectl config current-context 2>/dev/null || true)
  if [[ "$current" == k3d-* ]]; then echo "$current"; return 0; fi
  if kubectl config get-contexts -o name | grep -q '^k3d-k3s-default$'; then echo "k3d-k3s-default"; return 0; fi
  local k3d_contexts=()
  while IFS= read -r ctx; do [[ -n "$ctx" ]] && k3d_contexts+=("$ctx"); done < <(kubectl config get-contexts -o name | grep '^k3d-' || true)
  if [[ ${#k3d_contexts[@]} -eq 1 ]]; then echo "${k3d_contexts[0]}"; return 0; fi
  echo ""
}

print_usage() {
  cat <<EOF
Usage: bash scripts/submit-workflow.sh <FILE_OR_URL> [--watch]

Submits a workflow using ServiceAccount '$SA_NAME' to namespace '$ARGO_NS'.
Pass --watch to stream progress.
EOF
}

# Args
WATCH_FLAG=""
WF_SRC="${1:-}"
for arg in "$@"; do
  case "$arg" in
    --watch) WATCH_FLAG="--watch" ;;
  esac
done

if [[ -z "$WF_SRC" || "$WF_SRC" == --* ]]; then
  print_usage
  exit 1
fi

# Pre-checks
for bin in kubectl argo; do
  if ! command_exists "$bin"; then
    echo "[ERROR] Required binary '$bin' not found in PATH." >&2
    exit 1
  fi
done

KUBE_CONTEXT=$(choose_k3d_context "$K3D_CONTEXT")
if [[ -z "$KUBE_CONTEXT" ]]; then
  echo "[ERROR] Could not determine a unique k3d Kubernetes context. Set K3D_CONTEXT." >&2
  exit 1
fi

echo "[INFO] Using kube-context: $KUBE_CONTEXT"
kubectl config use-context "$KUBE_CONTEXT" >/dev/null

if ! kubectl get ns "$ARGO_NS" >/dev/null 2>&1; then
  echo "[ERROR] Namespace '$ARGO_NS' not found. Install Argo first: bash scripts/install-argo.sh" >&2
  exit 1
fi

if ! kubectl -n "$ARGO_NS" get sa "$SA_NAME" >/dev/null 2>&1; then
  echo "[ERROR] ServiceAccount '$SA_NAME' not found in namespace '$ARGO_NS'. Create it: bash scripts/setup-argo-admin.sh" >&2
  exit 1
fi

# Get SA token
TOKEN=""
set +e
TOKEN=$(kubectl -n "$ARGO_NS" create token "$SA_NAME" --duration=24h 2>/dev/null)
KCTL_CREATE_TOKEN_RC=$?
set -e
if [[ $KCTL_CREATE_TOKEN_RC -ne 0 || -z "$TOKEN" ]]; then
  echo "[WARN] 'kubectl create token' failed or unavailable. Falling back to Secret-based token."
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
  echo "[ERROR] Failed to obtain bearer token for ServiceAccount '$SA_NAME'." >&2
  exit 1
fi

echo "[INFO] Obtained token for SA '$SA_NAME'."

# Determine endpoint
USE_PORT_FORWARD="false"
SERVER_HOST="$ARGO_INGRESS_HOST"
SERVER_PORT="$K3D_HTTP_PORT"
if kubectl -n "$ARGO_NS" get ingressroute.traefik.io argo-server >/dev/null 2>&1 || \
   kubectl -n "$ARGO_NS" get ingress argo-server >/dev/null 2>&1; then
  echo "[INFO] Using ingress endpoint: http://$SERVER_HOST:$SERVER_PORT"
else
  echo "[INFO] No ingress found. Using temporary port-forward to localhost:2746"
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
  for i in {1..30}; do
    if nc -z "$SERVER_HOST" "$SERVER_PORT" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  if ! nc -z "$SERVER_HOST" "$SERVER_PORT" >/dev/null 2>&1; then
    echo "[ERROR] Failed to establish port-forward to argo-server on $SERVER_HOST:$SERVER_PORT" >&2
    exit 1
  fi
  echo "[INFO] Port-forward established (pid=$PF_PID)."
fi

ARGO_ADDR="$SERVER_HOST:$SERVER_PORT"
HELPOUT=$(argo submit --help 2>/dev/null || true)
RC=0
if echo "$HELPOUT" | grep -q -- "--auth-mode"; then
  echo "[INFO] Submitting via argo-server at $ARGO_ADDR using bearer token and ServiceAccount '$SA_NAME'"
  set +e
  argo submit ${WATCH_FLAG:+$WATCH_FLAG} \
    "$WF_SRC" \
    -n "$ARGO_NS" \
    --serviceaccount "$SA_NAME" \
    --server "$ARGO_ADDR" \
    --auth-mode bearer \
    --token "$TOKEN" \
    --insecure
  RC=$?
  set -e
else
  echo "[WARN] 'argo' CLI lacks server auth flags; submitting directly to K8s with ServiceAccount '$SA_NAME'"
  set +e
  argo submit ${WATCH_FLAG:+$WATCH_FLAG} \
    "$WF_SRC" \
    -n "$ARGO_NS" \
    --serviceaccount "$SA_NAME"
  RC=$?
  set -e
  if [[ $RC -ne 0 ]]; then
    echo "[WARN] 'argo submit' direct mode failed (exit code $RC). Falling back to 'kubectl create -f' with SA injection."
    TMP_YAML="$(mktemp)"
    # If source is URL, download; else copy
    if [[ "$WF_SRC" =~ ^https?:// ]]; then
      if ! curl -fsSL "$WF_SRC" -o "$TMP_YAML"; then
        echo "[ERROR] Failed to download workflow from $WF_SRC" >&2
        RC=$RC
      else
        DOWNLOAD_OK=1
      fi
    else
      cp "$WF_SRC" "$TMP_YAML"
      DOWNLOAD_OK=1
    fi

    if [[ ${DOWNLOAD_OK:-0} -eq 1 ]]; then
      if ! grep -qE '^\s*serviceAccountName:' "$TMP_YAML"; then
        awk -v sa="$SA_NAME" '
          /^spec:\s*$/{print; print "  serviceAccountName: " sa; next}
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

echo "[SUCCESS] Workflow submitted to namespace '$ARGO_NS'."
if [[ "$USE_PORT_FORWARD" == "true" ]]; then
  echo "[INFO] You can view it in the UI at: http://localhost:2746"
else
  echo "[INFO] You can view it in the UI at: http://$SERVER_HOST:$SERVER_PORT"
fi
