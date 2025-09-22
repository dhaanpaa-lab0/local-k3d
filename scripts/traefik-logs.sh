#!/usr/bin/env bash
set -euo pipefail

# traefik-logs.sh
# Helper to view or save Traefik logs from a local k3d/k3s cluster.
# - Auto-selects a k3d kube-context (override with K3D_CONTEXT)
# - Looks for Traefik pods in kube-system by default (override with TRAEFIK_NS)
# - Supports following logs, time range, and writing to a file under tmp/
#
# Usage:
#   bash scripts/traefik-logs.sh                   # print recent logs from all Traefik pods
#   bash scripts/traefik-logs.sh -f                # follow logs (like tail -f)
#   bash scripts/traefik-logs.sh --since=1h        # logs from the last hour
#   bash scripts/traefik-logs.sh --outfile         # write to tmp/traefik-logs-<ts>.log
#   TRAEFIK_NS=kube-system bash scripts/traefik-logs.sh -f --since=30m
#
# Environment variables:
#   K3D_CONTEXT   Override kube context. Default: auto-detect a k3d context
#   TRAEFIK_NS    Namespace where Traefik runs. Default: kube-system
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

K3D_CONTEXT="${K3D_CONTEXT:-}"
TRAEFIK_NS="${TRAEFIK_NS:-kube-system}"
FOLLOW="false"
SINCE_ARG=""
OUTFILE="false"
CONTAINER=""
ALL_PODS="true" # aggregate logs from all Traefik pods by default

print_help() {
  cat <<EOF
Traefik logs helper for k3d/k3s

Examples:
  bash scripts/traefik-logs.sh
  bash scripts/traefik-logs.sh -f --since=1h
  bash scripts/traefik-logs.sh --outfile
  K3D_CONTEXT=k3d-k3s-default bash scripts/traefik-logs.sh

Options:
  -f, --follow           Stream logs (follow)
      --since=<dur>      Show logs since duration (e.g., 10m, 1h, 2h)
      --container=<name> Specific container to log if pod has multiple
      --outfile          Write logs to tmp/traefik-logs-<timestamp>.log
  -h, --help             Show this help

Env:
  K3D_CONTEXT            Override kube context (auto-detects k3d if unset)
  TRAEFIK_NS             Namespace where Traefik runs (default: kube-system)
EOF
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

choose_k3d_context() {
  local desired_ctx="$1"
  if [[ -n "$desired_ctx" ]]; then
    echo "$desired_ctx"; return 0
  fi
  local current
  current=$(kubectl config current-context 2>/dev/null || true)
  if [[ "$current" == k3d-* ]]; then echo "$current"; return 0; fi
  if kubectl config get-contexts -o name | grep -q '^k3d-k3s-default$'; then
    echo "k3d-k3s-default"; return 0
  fi
  local k3d_contexts
  k3d_contexts=()
  while IFS= read -r ctx; do
    [[ -n "$ctx" ]] && k3d_contexts+=("$ctx")
  done < <(kubectl config get-contexts -o name | grep '^k3d-' || true)
  if [[ ${#k3d_contexts[@]} -eq 1 ]]; then echo "${k3d_contexts[0]}"; return 0; fi
  echo ""
}

# Parse args
for arg in "$@"; do
  case "$arg" in
    -f|--follow) FOLLOW="true" ;;
    --since=*) SINCE_ARG="${arg#*=}" ;;
    --container=*) CONTAINER="${arg#*=}" ;;
    --outfile) OUTFILE="true" ;;
    -h|--help) print_help; exit 0 ;;
    *) echo "[WARN] Unknown argument: $arg" ;;
  esac
done

for bin in kubectl; do
  if ! command_exists "$bin"; then
    echo "[ERROR] '$bin' is required but not found in PATH." >&2
    exit 1
  fi
done

KUBE_CONTEXT=$(choose_k3d_context "$K3D_CONTEXT")
if [[ -z "$KUBE_CONTEXT" ]]; then
  echo "[ERROR] Could not determine a unique k3d Kubernetes context. Set K3D_CONTEXT explicitly." >&2
  exit 1
fi

echo "[INFO] Using kube-context: $KUBE_CONTEXT"
kubectl config use-context "$KUBE_CONTEXT" >/dev/null

# Find Traefik pods (support common labels)
# Prefer the standard Helm label used by k3s bundled Traefik: app.kubernetes.io/name=traefik
# Also try k8s-app=traefik as a fallback.
PODS=()
while IFS= read -r p; do
  [[ -n "$p" ]] && PODS+=("$p")
done < <(
  kubectl -n "$TRAEFIK_NS" get pods -l app.kubernetes.io/name=traefik -o name 2>/dev/null || true
)
if [[ ${#PODS[@]} -eq 0 ]]; then
  while IFS= read -r p; do
    [[ -n "$p" ]] && PODS+=("$p")
  done < <(
    kubectl -n "$TRAEFIK_NS" get pods -l k8s-app=traefik -o name 2>/dev/null || true
  )
fi

if [[ ${#PODS[@]} -eq 0 ]]; then
  echo "[ERROR] No Traefik pods found in namespace '$TRAEFIK_NS'." >&2
  echo "        Verify Traefik is installed and running. Try: kubectl -n $TRAEFIK_NS get pods" >&2
  exit 1
fi

echo "[INFO] Found Traefik pods: ${PODS[*]}"

LOG_ARGS=(logs)
if [[ "$ALL_PODS" == "true" ]]; then LOG_ARGS+=(--all-containers=false); fi
if [[ "$FOLLOW" == "true" ]]; then LOG_ARGS+=(-f); fi
if [[ -n "$SINCE_ARG" ]]; then LOG_ARGS+=(--since="$SINCE_ARG"); fi
if [[ -n "$CONTAINER" ]]; then LOG_ARGS+=(-c "$CONTAINER"); fi

# Build output destination
if [[ "$OUTFILE" == "true" ]]; then
  mkdir -p "$REPO_ROOT/tmp"
  TS=$(date +%Y%m%d-%H%M%S)
  OUT_PATH="$REPO_ROOT/tmp/traefik-logs-$TS.log"
  echo "[INFO] Writing logs to: $OUT_PATH"
  # Use --prefix to include pod name
  kubectl -n "$TRAEFIK_NS" "${LOG_ARGS[@]}" --prefix "${PODS[@]}" | tee "$OUT_PATH"
else
  kubectl -n "$TRAEFIK_NS" "${LOG_ARGS[@]}" --prefix "${PODS[@]}"
fi
