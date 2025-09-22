#!/usr/bin/env bash
set -euo pipefail

# install-argo.sh
# Installs Argo Workflows CLI and deploys Argo Workflows into the default k3d cluster.
# - Detects/uses a k3d Kubernetes context (defaults to k3d-k3s-default when present).
# - Installs Argo CLI (via Homebrew if available on macOS; otherwise via direct download).
# - Applies the official Argo Workflows install manifest into the "argo" namespace.
# - Waits for core Argo components to become Ready.
#
# Environment variables:
#   ARGO_VERSION   Set a specific Argo Workflows version tag (e.g., v3.5.8). Default: v3.5.8
#   K3D_CONTEXT    Override the kube context to use. If unset, auto-detects a k3d context.
#   ARGO_NS        Namespace for Argo installation. Default: argo
#
# Usage:
#   bash scripts/install-argo.sh

ARGO_VERSION="${ARGO_VERSION:-v3.5.8}"
ARGO_NS="${ARGO_NS:-argo}"
K3D_CONTEXT="${K3D_CONTEXT:-}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

echo "[INFO] Verifying prerequisites..."
for bin in kubectl curl; do
  if ! command_exists "$bin"; then
    echo "[ERROR] '$bin' is required but not found in PATH." >&2
    exit 1
  fi
done

# gunzip required only when doing direct binary install
if ! command_exists gunzip; then
  echo "[WARN] 'gunzip' not found. Will attempt Homebrew install for CLI on macOS; otherwise, please install gzip package if direct download is needed."
fi

# Detect or verify k3d context
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

  # Prefer the common default context if present
  if kubectl config get-contexts -o name | grep -q '^k3d-k3s-default$'; then
    echo "k3d-k3s-default"
    return 0
  fi

  # Fallback: if exactly one k3d context exists, use it
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

KUBE_CONTEXT=$(choose_k3d_context "$K3D_CONTEXT")
if [[ -z "$KUBE_CONTEXT" ]]; then
  echo "[ERROR] Could not determine a unique k3d Kubernetes context."
  echo "        - Ensure your k3d cluster is created (e.g., 'k3d cluster create')."
  echo "        - Or set K3D_CONTEXT explicitly (e.g., 'export K3D_CONTEXT=k3d-k3s-default')."
  exit 1
fi

echo "[INFO] Using kube-context: $KUBE_CONTEXT"
kubectl config use-context "$KUBE_CONTEXT" >/dev/null

install_argo_cli_brew() {
  if [[ "$(uname -s)" == "Darwin" ]] && command_exists brew; then
    echo "[INFO] Installing Argo CLI via Homebrew..."
    if brew list --formula argo >/dev/null 2>&1; then
      echo "[INFO] 'argo' formula already installed."
    else
      brew install argo
    fi
    return 0
  fi
  return 1
}

install_argo_cli_direct() {
  if command_exists argo; then
    echo "[INFO] argo CLI already installed: $(command -v argo)"
    return 0
  fi

  local os arch url tmp gz name
  os=$(uname -s)
  arch=$(uname -m)

  case "$os" in
    Linux) name="argo-linux" ;;
    Darwin) name="argo-darwin" ;;
    *) echo "[ERROR] Unsupported OS: $os"; return 1 ;;
  esac

  case "$arch" in
    x86_64|amd64) name+="-amd64" ;;
    arm64|aarch64) name+="-arm64" ;;
    *) echo "[ERROR] Unsupported architecture: $arch"; return 1 ;;
  esac

  url="https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/${name}.gz"
  tmp=$(mktemp -d)
  gz="$tmp/${name}.gz"

  echo "[INFO] Downloading argo CLI from: $url"
  if ! curl -fsSL "$url" -o "$gz"; then
    echo "[ERROR] Failed to download $url" >&2
    rm -rf "$tmp"
    return 1
  fi

  if ! command_exists gunzip; then
    echo "[ERROR] 'gunzip' not available to extract archive. Please install gzip and re-run." >&2
    rm -rf "$tmp"
    return 1
  fi

  gunzip "$gz"
  chmod +x "$tmp/${name}"

  local target
  for target in /usr/local/bin/argo /usr/bin/argo "$HOME/.local/bin/argo"; do
    local dir
    dir=$(dirname "$target")
    if [[ -w "$dir" ]]; then
      mv "$tmp/${name}" "$target"
      echo "[INFO] Installed argo CLI to: $target"
      rm -rf "$tmp"
      return 0
    fi
  done

  echo "[WARN] No writable system bin directory found. Attempting to install under ~/.local/bin"
  mkdir -p "$HOME/.local/bin"
  mv "$tmp/${name}" "$HOME/.local/bin/argo"
  echo "[INFO] Installed argo CLI to: $HOME/.local/bin/argo"
  echo "[INFO] Ensure $HOME/.local/bin is in your PATH."
  rm -rf "$tmp"
  return 0
}

install_argo_cli() {
  if command_exists argo; then
    echo "[INFO] argo CLI already present: $(command -v argo)"
    return 0
  fi

  if install_argo_cli_brew; then
    echo "[INFO] argo CLI installed via Homebrew."
    return 0
  fi

  install_argo_cli_direct
}

# Install the CLI (idempotent)
install_argo_cli

echo "[INFO] Creating namespace '$ARGO_NS' (if not exists)..."
kubectl get ns "$ARGO_NS" >/dev/null 2>&1 || kubectl create namespace "$ARGO_NS"

INSTALL_URL="https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/install.yaml"

echo "[INFO] Applying Argo Workflows manifest: $INSTALL_URL"
kubectl apply -n "$ARGO_NS" -f "$INSTALL_URL"

# Wait for core components to be ready
components=(
  deployment/argo-server
  deployment/workflow-controller
)

echo "[INFO] Waiting for Argo components to become ready in namespace '$ARGO_NS'..."
for c in "${components[@]}"; do
  echo "[INFO] Waiting for rollout of $c"
  # Use a generous timeout; clusters may take time to pull images first time
  if ! kubectl -n "$ARGO_NS" rollout status "$c" --timeout=180s; then
    echo "[WARN] Rollout for $c did not complete within timeout. Continuing..."
  fi
done

echo "[SUCCESS] Argo Workflows installed in namespace '$ARGO_NS' on context '$KUBE_CONTEXT'."

cat <<EOF
Next steps:
- Submit a sample workflow: argo submit --watch https://raw.githubusercontent.com/argoproj/argo-workflows/${ARGO_VERSION}/examples/hello-world.yaml -n $ARGO_NS
- Access the Argo UI via port-forward:
    kubectl -n $ARGO_NS port-forward svc/argo-server 2746:2746
  Then open: http://localhost:2746
EOF
