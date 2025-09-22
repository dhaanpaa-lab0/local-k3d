#!/usr/bin/env bash
set -euo pipefail

# setup-step-issuer.sh
# Prepares a StepClusterIssuer manifest in tmp/ from k8s/step-cluster-issuer.yaml
# by substituting values discovered from the local cluster (preferred) or env-provided
# values, then applies it from tmp/.
#
# Usage:
#   bash scripts/setup-step-issuer.sh
#
# Env:
#   K3D_CONTEXT                Optional kube context (auto-detect k3d if empty)
#   STEP_CA_BUNDLE_FILE        Path to a PEM file containing the step-ca root certificate (fallback)
#   STEP_CA_BUNDLE             PEM content of the root certificate (multi-line supported; fallback)
#   STEP_PROVISIONER_PASSWORD  Password for the step provisioner (fallback)
#   TEMPLATE_FILE              Optional path to source template (default: k8s/step-cluster-issuer.yaml)
#   OUTPUT_FILE                Optional output path (default: tmp/step-cluster-issuer.yaml)
#
# Notes:
# - The script will first try to auto-discover the root CA bundle and provisioner password
#   from the local cluster (namespace: step-system). If not found, it falls back to env vars.
# - If required values are still missing, the script writes a templated file to tmp/ and
#   prints instructions to fill placeholders, then exits non-zero.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="${TEMPLATE_FILE:-$REPO_ROOT/k8s/step-cluster-issuer.yaml}"
OUTPUT_FILE="${OUTPUT_FILE:-$REPO_ROOT/tmp/step-cluster-issuer.yaml}"

mkdir -p "$REPO_ROOT/tmp"

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

fetch_ca_bundle_from_cluster() {
  # Try common secret/configmap names and keys created by the step-certificates chart
  local ns="${1:-step-system}"
  local data
  # Secrets (base64)
  for name in \
    step-certificates-root-ca \
    step-certificates-ca \
    step-ca-root-ca \
    step-ca-root \
    step-certificates \
    step-ca-step-certificates-certs \
    step-ca-step-certificates-root-ca \
    step-ca-step-certificates-ca \
    step-ca; do
    for key in ca.crt root-ca.crt tls.crt root_ca.crt ca \
      root-ca pem crt; do
      if data=$(kubectl -n "$ns" get secret "$name" -o jsonpath="{.data['$key']}" 2>/dev/null || true); then
        if [[ -n "$data" ]]; then
          # Some clusters may not base64-encode in our assumption; try decode then fallback
          decoded=$(echo "$data" | base64 --decode 2>/dev/null || echo "$data" | base64 -D 2>/dev/null || true)
          if grep -q "BEGIN CERTIFICATE" <<<"$decoded"; then
            printf "%s" "$decoded"
            return 0
          fi
        fi
      fi
    done
  done
  # ConfigMaps (plain text)
  for name in \
    step-certificates-root-ca \
    step-certificates-ca \
    step-ca-root-ca \
    step-ca-step-certificates-root-ca \
    step-ca-step-certificates-ca; do
    for key in ca.crt root-ca.crt root_ca.crt ca root-ca pem crt; do
      if data=$(kubectl -n "$ns" get configmap "$name" -o jsonpath="{.data['$key']}" 2>/dev/null || true); then
        if [[ -n "$data" ]]; then
          if grep -q "BEGIN CERTIFICATE" <<<"$data"; then
            printf "%s" "$data"
            return 0
          fi
        fi
      fi
    done
  done
  # Fallback: scan all secrets in the namespace for any of the common keys
  local resource
  for resource in $(kubectl -n "$ns" get secrets -o name 2>/dev/null || true); do
    for key in ca.crt root-ca.crt root_ca.crt tls.crt ca root-ca pem crt; do
      if data=$(kubectl -n "$ns" get "$resource" -o jsonpath="{.data['$key']}" 2>/dev/null || true); then
        if [[ -n "$data" ]]; then
          decoded=$(echo "$data" | base64 --decode 2>/dev/null || echo "$data" | base64 -D 2>/dev/null || true)
          if grep -q "BEGIN CERTIFICATE" <<<"$decoded"; then
            printf "%s" "$decoded"
            return 0
          fi
        fi
      fi
    done
  done
  # Fallback: scan all configmaps
  for resource in $(kubectl -n "$ns" get configmaps -o name 2>/dev/null || true); do
    for key in ca.crt root-ca.crt root_ca.crt ca root-ca pem crt; do
      if data=$(kubectl -n "$ns" get "$resource" -o jsonpath="{.data['$key']}" 2>/dev/null || true); then
        if [[ -n "$data" ]] && grep -q "BEGIN CERTIFICATE" <<<"$data"; then
          printf "%s" "$data"
          return 0
        fi
      fi
    done
  done
  return 1
}

fetch_provisioner_password_from_cluster() {
  local ns="${1:-step-system}"
  local data
  for name in \
    step-certificates-provisioner-password \
    step-certificates-password \
    step-ca-provisioner-password \
    step-provisioner-password; do
    for key in password PROVISIONER_PASSWORD provisionerPassword; do
      if data=$(kubectl -n "$ns" get secret "$name" -o jsonpath="{.data['$key']}" 2>/dev/null || true); then
        if [[ -n "$data" ]]; then
          echo "$data" | base64 --decode 2>/dev/null || echo "$data" | base64 -D 2>/dev/null
          return 0
        fi
      fi
    done
  done
  return 1
}

: "${KUBECONFIG:=}"
K3D_CONTEXT="${K3D_CONTEXT:-}"
STEP_CA_BUNDLE_FILE="${STEP_CA_BUNDLE_FILE:-}"
STEP_CA_BUNDLE="${STEP_CA_BUNDLE:-}"
STEP_PROVISIONER_PASSWORD="${STEP_PROVISIONER_PASSWORD:-}"

if ! command_exists kubectl; then
  echo "[ERROR] kubectl is required in PATH." >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "[ERROR] Template not found: $TEMPLATE_FILE" >&2
  exit 1
fi

# Ensure we are on a k3d context early so cluster discovery works
CTX=$(choose_k3d_context "$K3D_CONTEXT")
if [[ -n "$CTX" ]]; then
  echo "[INFO] Using kube-context: $CTX"
  kubectl config use-context "$CTX" >/dev/null
else
  echo "[WARN] No k3d context auto-detected; using current kubectl context."
fi

# Try to auto-discover values from the cluster if not provided
if [[ -z "$STEP_CA_BUNDLE" && -z "${STEP_CA_BUNDLE_FILE}" ]]; then
  if CA_DISCOVERED=$(fetch_ca_bundle_from_cluster step-system 2>/dev/null); then
    if [[ -n "$CA_DISCOVERED" ]]; then
      echo "[INFO] Discovered step-ca root CA from cluster (namespace step-system)."
      STEP_CA_BUNDLE="$CA_DISCOVERED"
    fi
  fi
fi
if [[ -z "$STEP_PROVISIONER_PASSWORD" ]]; then
  if PW_DISCOVERED=$(fetch_provisioner_password_from_cluster step-system 2>/dev/null); then
    if [[ -n "$PW_DISCOVERED" ]]; then
      echo "[INFO] Discovered step-ca provisioner password from cluster (namespace step-system)."
      STEP_PROVISIONER_PASSWORD="$PW_DISCOVERED"
    fi
  fi
fi

# Read CA bundle content from file if provided (fallback)
if [[ -z "$STEP_CA_BUNDLE" && -n "$STEP_CA_BUNDLE_FILE" ]]; then
  if [[ ! -f "$STEP_CA_BUNDLE_FILE" ]]; then
    echo "[ERROR] STEP_CA_BUNDLE_FILE does not exist: $STEP_CA_BUNDLE_FILE" >&2
    exit 1
  fi
  STEP_CA_BUNDLE=$(cat "$STEP_CA_BUNDLE_FILE")
fi

# Prepare output by copying template first
cp "$TEMPLATE_FILE" "$OUTPUT_FILE"

# Substitute provisioner password if provided
if [[ -n "$STEP_PROVISIONER_PASSWORD" ]]; then
  # Replace the quoted placeholder value
  sed -i.bak "s#\"REPLACE_WITH_PROVISIONER_PASSWORD\"#\"${STEP_PROVISIONER_PASSWORD//#/\\#}\"#g" "$OUTPUT_FILE"
  rm -f "$OUTPUT_FILE.bak"
fi

# Substitute CA bundle if provided
if [[ -n "$STEP_CA_BUNDLE" ]]; then
  # 1) Preferred path: template expects base64 string (REPLACE_WITH_CA_BUNDLE_B64)
  CA_B64=$(printf '%s' "$STEP_CA_BUNDLE" | base64 | tr -d '\r\n')
  if grep -q 'REPLACE_WITH_CA_BUNDLE_B64' "$OUTPUT_FILE"; then
    sed -i.bak "s#REPLACE_WITH_CA_BUNDLE_B64#${CA_B64//#/\\#}#g" "$OUTPUT_FILE"
    rm -f "$OUTPUT_FILE.bak"
  else
    # 2) Legacy path: if template uses a PEM block with 'caBundle: |', preserve previous behavior
    INDENTED_BUNDLE="$(printf '%s\n' "$STEP_CA_BUNDLE" | sed 's/^/    /')"
    awk -v repl="$INDENTED_BUNDLE" '
      BEGIN{in_ca=0}
      /^(caBundle: \|)/{print; print repl; in_ca=1; skip=1; next}
      in_ca==1 {
        if ($0 ~ /^    -----END CERTIFICATE-----/){ in_ca=0; next }
        if ($0 ~ /^  provisioner:/){ in_ca=0; print; next }
        next
      }
      {print}
    ' "$OUTPUT_FILE" > "$OUTPUT_FILE.tmp" && mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"
  fi
fi

# Determine if placeholders remain
if grep -q 'REPLACE_WITH_' "$OUTPUT_FILE"; then
  echo "[WARN] One or more placeholders remain in $OUTPUT_FILE" >&2
  echo "[INFO] Please open the file and replace placeholders, or rerun with env vars:" >&2
  echo "       STEP_CA_BUNDLE_FILE=path/to/root_ca.pem STEP_PROVISIONER_PASSWORD=... bash scripts/setup-step-issuer.sh" >&2
  # Do not apply invalid manifest
  exit 2
fi

echo "[INFO] Applying StepClusterIssuer from $OUTPUT_FILE ..."
kubectl apply -f "$OUTPUT_FILE"

# Basic check
echo "[INFO] Verifying StepClusterIssuer resource..."
kubectl get stepclusterissuer.certmanager.step.sm step-ca-cluster-issuer -n cert-manager >/dev/null 2>&1 || true

echo "[DONE] StepClusterIssuer applied from $OUTPUT_FILE"
