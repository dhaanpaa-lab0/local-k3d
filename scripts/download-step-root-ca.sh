#!/usr/bin/env bash
set -euo pipefail

# download-step-root-ca.sh
# Fetch the Smallstep step-ca root CA certificate from the local cluster and
# write it to a file (default: tmp/step-root-ca.pem). Prints the output path.
#
# Usage:
#   bash scripts/download-step-root-ca.sh
#
# Env:
#   K3D_CONTEXT   Optional kube context (auto-detects a k3d-* context if unset)
#   NAMESPACE     Namespace where step-certificates is installed (default: step-system)
#   OUTPUT_FILE   Where to write the PEM file (default: tmp/step-root-ca.pem)
#   PRINT_ONLY    If set to '1', prints the PEM to stdout instead of writing to a file
#
# Exit codes:
#   0 - Success
#   1 - Missing dependencies or unexpected error
#   2 - Could not discover a root CA in the cluster

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="${NAMESPACE:-step-system}"
OUTPUT_FILE="${OUTPUT_FILE:-$REPO_ROOT/tmp/step-root-ca.pem}"
PRINT_ONLY="${PRINT_ONLY:-0}"

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
  local ns="${1:-step-system}"
  local data
  # Secrets (base64)
  for name in \
    step-certificates-root-ca \
    step-certificates-ca \
    step-ca-root-ca \
    step-ca-root \
    step-certificates \
    step-ca-step-certificates-root-ca \
    step-ca-step-certificates-ca \
    tep-ca-step-certificates-certs \
    step-ca; do
    for key in ca.crt root-ca.crt tls.crt root_ca.crt ca root-ca pem crt; do
      if data=$(kubectl -n "$ns" get secret "$name" -o jsonpath="{.data['$key']}" 2>/dev/null || true); then
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
  # ConfigMaps (plain text)
  for name in \
    step-certificates-root-ca \
    step-certificates-ca \
    step-ca-root-ca \
    step-ca-step-certificates-root-ca \
    step-ca-step-certificates-ca; do
    for key in ca.crt root-ca.crt root_ca.crt ca root-ca pem crt; do
      if data=$(kubectl -n "$ns" get configmap "$name" -o jsonpath="{.data['$key']}" 2>/dev/null || true); then
        if [[ -n "$data" ]] && grep -q "BEGIN CERTIFICATE" <<<"$data"; then
          printf "%s" "$data"
          return 0
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

# Ensure dependencies
if ! command_exists kubectl; then
  echo "[ERROR] kubectl is required in PATH." >&2
  exit 1
fi

# Pick a k3d context if available
K3D_CONTEXT="${K3D_CONTEXT:-}"
CTX=$(choose_k3d_context "$K3D_CONTEXT")
if [[ -n "$CTX" ]]; then
  echo "[INFO] Using kube-context: $CTX"
  kubectl config use-context "$CTX" >/dev/null
else
  echo "[WARN] No k3d context auto-detected; using current kubectl context."
fi

# Fetch the CA
if ! CA_PEM=$(fetch_ca_bundle_from_cluster "$NAMESPACE" 2>/dev/null); then
  echo "[ERROR] Could not find a step-ca root CA in namespace '$NAMESPACE'." >&2
  echo "        Ensure step-certificates is installed and Ready, then try again." >&2
  exit 2
fi

# Basic sanity: look for PEM header/footer
if ! grep -q 'BEGIN CERTIFICATE' <<<"$CA_PEM"; then
  echo "[WARN] Retrieved data does not look like a PEM certificate. Writing anyway." >&2
fi

if [[ "$PRINT_ONLY" == "1" ]]; then
  printf '%s\n' "$CA_PEM"
  exit 0
fi

# Write to file
printf '%s\n' "$CA_PEM" > "$OUTPUT_FILE"
chmod 0644 "$OUTPUT_FILE" || true

echo "[DONE] Wrote root CA PEM to: $OUTPUT_FILE"
