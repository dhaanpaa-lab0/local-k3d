#!/usr/bin/env bash
set -euo pipefail

# config-argo-adm-acct.sh
# Creates an Argo Workflows admin ServiceAccount and writes usage instructions to tmp/.
# - Targets a k3d/k3s cluster context similar to other scripts in this repo.
# - By default uses namespace "argo" (configurable with ARGO_NS).
# - Binds the ServiceAccount to cluster-admin for simplicity in local dev.
# - Retrieves a bearer token for the ServiceAccount (kubectl create token preferred).
# - Writes instructions (UI and CLI) to tmp/argo-admin-instructions.txt.
#
# Environment variables:
#   K3D_CONTEXT         Override kube context to use. Default: auto-detect k3d context.
#   ARGO_NS             Namespace to use. Default: argo
#   SA_NAME             ServiceAccount name. Default: argo-admin
#   K3D_HTTP_PORT       Host port for Traefik HTTP entrypoint (LB 80). Default: 8281 (matches other scripts)
#   ARGO_INGRESS_HOST   Host for ingress if set up (e.g., argo.localtest.me). Optional.
#
# Usage:
#   bash scripts/config-argo-adm-acct.sh
#   ARGO_NS=argo SA_NAME=argo-admin bash scripts/config-argo-adm-acct.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ARGO_NS="${ARGO_NS:-argo}"
SA_NAME="${SA_NAME:-argo-admin}"
K3D_CONTEXT="${K3D_CONTEXT:-}"
K3D_HTTP_PORT="${K3D_HTTP_PORT:-8281}"
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

# Create ServiceAccount (idempotent)
if kubectl -n "$ARGO_NS" get sa "$SA_NAME" >/dev/null 2>&1; then
  echo "[INFO] ServiceAccount '$SA_NAME' already exists in namespace '$ARGO_NS'."
else
  echo "[INFO] Creating ServiceAccount '$SA_NAME' in namespace '$ARGO_NS'..."
  kubectl -n "$ARGO_NS" create sa "$SA_NAME"
fi

# Bind to cluster-admin for local development convenience
CRB_NAME="${SA_NAME}-cluster-admin"
if kubectl get clusterrolebinding "$CRB_NAME" >/dev/null 2>&1; then
  echo "[INFO] ClusterRoleBinding '$CRB_NAME' already exists."
else
  echo "[INFO] Creating ClusterRoleBinding '$CRB_NAME' to cluster-admin..."
  kubectl create clusterrolebinding "$CRB_NAME" \
    --clusterrole=cluster-admin \
    --serviceaccount="${ARGO_NS}:${SA_NAME}"
fi

# Ensure Argo Server RBAC allows this ServiceAccount to log in (policy.csv)
echo "[INFO] Ensuring Argo RBAC grants admin to SA '${SA_NAME}'..."
CM_NAME="workflow-controller-configmap"
P_LINE="p, role:admin, *, *, *, allow"
G_LINE="g, system:serviceaccount:${ARGO_NS}:${SA_NAME}, role:admin"

# Get existing policy if present
set +e
EXISTING_POLICY=$(kubectl -n "$ARGO_NS" get configmap "$CM_NAME" -o jsonpath='{.data.policy\.csv}' 2>/dev/null)
HAS_CM=$?
set -e

NEW_POLICY=""
if [[ $HAS_CM -ne 0 || -z "$EXISTING_POLICY" ]]; then
  NEW_POLICY="$P_LINE"$'\n'"$G_LINE"
else
  NEW_POLICY="$EXISTING_POLICY"
  if ! echo "$NEW_POLICY" | grep -qF "$P_LINE"; then
    NEW_POLICY+=$'\n'"$P_LINE"
  fi
  if ! echo "$NEW_POLICY" | grep -qF "$G_LINE"; then
    NEW_POLICY+=$'\n'"$G_LINE"
  fi
fi

# Escape for JSON patch
ESC_POLICY=$(printf "%s" "$NEW_POLICY" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/; $s/\\n$//; s/\n/\\n/g')

PATCH_JSON=$(cat <<JSON
{"data":{"policy.csv":"$ESC_POLICY","policy.default":"role:admin"}}
JSON
)

if [[ $HAS_CM -ne 0 ]]; then
  echo "[INFO] Creating ConfigMap '$CM_NAME' with Argo RBAC policy in namespace '$ARGO_NS'..."
  kubectl -n "$ARGO_NS" create configmap "$CM_NAME" \
    --from-literal=policy.csv="$NEW_POLICY" \
    --from-literal=policy.default="role:admin" >/dev/null || true
else
  echo "[INFO] Patching ConfigMap '$CM_NAME' to include Argo RBAC policy..."
  kubectl -n "$ARGO_NS" patch configmap "$CM_NAME" --type merge -p "$PATCH_JSON" >/dev/null || true
fi

echo "[INFO] Argo RBAC configured. If you previously saw 'Forbidden' in the UI, refresh and use the SA token."

# Retrieve a token for the ServiceAccount
TOKEN=""
set +e
TOKEN=$(kubectl -n "$ARGO_NS" create token "$SA_NAME" --duration=24h 2>/dev/null)
KCTL_CREATE_TOKEN_RC=$?
set -e

if [[ $KCTL_CREATE_TOKEN_RC -ne 0 || -z "$TOKEN" ]]; then
  echo "[WARN] 'kubectl create token' failed or is unavailable. Falling back to secret-based token retrieval."
  # Ensure a token Secret exists (for clusters that still support auto-generated secrets this may already exist).
  # If not, create a token secret bound to the SA (supported on k8s >=1.24 as well).
  SECRET_NAME="${SA_NAME}-token"
  if ! kubectl -n "$ARGO_NS" get secret "$SECRET_NAME" >/dev/null 2>&1; then
    kubectl -n "$ARGO_NS" create secret generic "$SECRET_NAME" \
      --type=kubernetes.io/service-account-token \
      --from-literal=placeholder=dummy >/dev/null 2>&1 || true
    kubectl -n "$ARGO_NS" patch secret "$SECRET_NAME" -p "{\"metadata\":{\"annotations\":{\"kubernetes.io/service-account.name\":\"$SA_NAME\"}}}" >/dev/null
    # Wait a moment for controller to populate token
    echo "[INFO] Waiting for token controller to populate the secret..."
    sleep 2
  fi
  TOKEN=$(kubectl -n "$ARGO_NS" get secret "$SECRET_NAME" -o jsonpath='{.data.token}' | base64 --decode || true)
fi

if [[ -z "$TOKEN" ]]; then
  echo "[ERROR] Failed to obtain a token for ServiceAccount '$SA_NAME' in namespace '$ARGO_NS'." >&2
  exit 1
fi

echo "[INFO] Successfully obtained token for ServiceAccount '$SA_NAME'."

# Prepare instructions
TMP_DIR="$REPO_ROOT/tmp"
mkdir -p "$TMP_DIR"
OUT_FILE="$TMP_DIR/argo-admin-instructions.txt"

HOST_HINT="${ARGO_INGRESS_HOST:-argo.localtest.me}"

cat > "$OUT_FILE" <<EOF
Argo Workflows Admin User Instructions
=====================================

Context:    $KUBE_CONTEXT
Namespace:  $ARGO_NS
ServiceAccount: $SA_NAME

Token (validity may vary):
$TOKEN

How to use this token:

1) Via kubectl port-forward (local access):
   kubectl -n $ARGO_NS port-forward svc/argo-server 2746:2746
   Then open http://localhost:2746 in your browser.
   - When prompted to log in, select the option to use a bearer token and paste the token above.

2) Via ingress (if you've run scripts/setup-argo-ingress.sh):
   URL: http://$HOST_HINT:$K3D_HTTP_PORT
   - Use the same bearer token above when logging in.

3) CLI login using argo CLI:
   a) Port-forward method:
      argo login localhost:2746 \
        --auth-mode bearer \
        --token "$TOKEN" \
        --insecure \
        --username ignored \
        --password ignored \
        --kube-context "$KUBE_CONTEXT" \
        --namespace "$ARGO_NS"

   b) Ingress method (HTTP via Traefik on host port $K3D_HTTP_PORT):
      argo login $HOST_HINT:$K3D_HTTP_PORT \
        --auth-mode bearer \
        --token "$TOKEN" \
        --insecure \
        --username ignored \
        --password ignored \
        --kube-context "$KUBE_CONTEXT" \
        --namespace "$ARGO_NS"

Submit a sample workflow to verify permissions:
   argo submit --watch \
     https://raw.githubusercontent.com/argoproj/argo-workflows/v3.5.8/examples/hello-world.yaml \
     -n $ARGO_NS

Notes:
- This ServiceAccount is bound to cluster-admin for convenience in local development. Do NOT use this in production.
- If the token expires, re-run this script to obtain a fresh token, or use:
    kubectl -n $ARGO_NS create token $SA_NAME --duration=24h

Generated: $(date -u)
EOF

echo "[INFO] Wrote instructions to: $OUT_FILE"
