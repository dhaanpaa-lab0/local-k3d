#!/usr/bin/env bash
set -euo pipefail

# install-k3d.sh
# Creates a local k3d cluster with HTTP and HTTPS ports exposed on the host.
# - Exposes Traefik HTTP on host ${K3D_HTTP_PORT:-8281} -> LB 80
# - Exposes Traefik HTTPS on host ${K3D_HTTPS_PORT:-8443} -> LB 443
# - Exposes Kubernetes API on host ${K3D_API_PORT:-6550}
#
# Environment variables:
#   K3D_CLUSTER     Cluster name. Default: k3s-default
#   K3D_AGENTS      Number of agent nodes. Default: 2
#   K3D_API_PORT    Host port for Kubernetes API. Default: 6550
#   K3D_HTTP_PORT   Host port forwarded to LB port 80. Default: 8281
#   K3D_HTTPS_PORT  Host port forwarded to LB port 443. Default: 8443
#
# Usage:
#   bash scripts/install-k3d.sh
#   K3D_CLUSTER=mycluster K3D_AGENTS=1 bash scripts/install-k3d.sh
#

K3D_CLUSTER="${K3D_CLUSTER:-k3s-default}"
K3D_AGENTS="${K3D_AGENTS:-2}"
K3D_API_PORT="${K3D_API_PORT:-6550}"
K3D_HTTP_PORT="${K3D_HTTP_PORT:-8281}"
K3D_HTTPS_PORT="${K3D_HTTPS_PORT:-8443}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

echo "[INFO] Verifying prerequisites..."
if ! command_exists k3d; then
  echo "[ERROR] 'k3d' command not found. Please install k3d: https://k3d.io/" >&2
  exit 1
fi

# Optional but commonly required
if ! command_exists docker && ! command_exists colima; then
  echo "[WARN] Docker (or an alternative runtime) not found in PATH. Ensure your container runtime is running before creating the cluster."
fi

# Idempotency: if cluster exists, print and exit
if k3d cluster list | awk 'NR>1 {print $1}' | grep -qx "$K3D_CLUSTER"; then
  echo "[INFO] k3d cluster '$K3D_CLUSTER' already exists. Skipping creation."
  echo "[INFO] To delete it: bash scripts/destroy-k3d.sh $K3D_CLUSTER"
  exit 0
fi

echo "[INFO] Creating k3d cluster: $K3D_CLUSTER"
k3d cluster create "$K3D_CLUSTER" \
  --api-port "$K3D_API_PORT" \
  -p "${K3D_HTTP_PORT}:80@loadbalancer" \
  -p "${K3D_HTTPS_PORT}:443@loadbalancer" \
  --agents "$K3D_AGENTS"

echo "[INFO] Cluster '$K3D_CLUSTER' created."
# Show helpful context info
if command_exists kubectl; then
  K3D_CONTEXT="k3d-$K3D_CLUSTER"
  echo "[INFO] You can switch kubectl context with: kubectl config use-context $K3D_CONTEXT"
  echo "[INFO] Current contexts:" 
  kubectl config get-contexts -o name | sed 's/^/[INFO]   /'
fi

echo "[INFO] HTTP  -> http://localtest.me:${K3D_HTTP_PORT}"
echo "[INFO] HTTPS -> https://localtest.me:${K3D_HTTPS_PORT}"

