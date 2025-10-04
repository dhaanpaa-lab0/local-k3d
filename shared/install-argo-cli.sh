#!/usr/bin/env bash

# Detect OS
ARGO_OS=""
case "$(uname -s)" in
  Darwin)
    ARGO_OS="darwin"
    ;;
  Linux)
    ARGO_OS="linux"
    ;;
  CYGWIN*|MINGW32*|MSYS*|MINGW*)
    ARGO_OS="windows"
    ;;
  *)
    echo "Unsupported operating system: $(uname -s)"
    exit 1
    ;;
esac

# Detect architecture
ARGO_ARCH=""
case "$(uname -m)" in
  x86_64|amd64)
    ARGO_ARCH="amd64"
    ;;
  arm64|aarch64)
    ARGO_ARCH="arm64"
    ;;
  armv7l)
    ARGO_ARCH="arm"
    ;;
  s390x)
    ARGO_ARCH="s390x"
    ;;
  ppc64le)
    ARGO_ARCH="ppc64le"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)"
    exit 1
    ;;
esac

echo "Detected OS: $ARGO_OS, Architecture: $ARGO_ARCH"

# Set file extension for Windows
FILE_EXT=""
if [[ "$ARGO_OS" == "windows" ]]; then
  FILE_EXT=".exe"
fi

# Download the binary
echo "Downloading argo-$ARGO_OS-$ARGO_ARCH..."
curl -sLO "https://github.com/argoproj/argo-workflows/releases/download/v3.7.2/argo-$ARGO_OS-$ARGO_ARCH.gz"

# Check if download was successful
if [[ ! -f "argo-$ARGO_OS-$ARGO_ARCH.gz" ]]; then
  echo "Failed to download argo binary for $ARGO_OS-$ARGO_ARCH"
  echo "This combination might not be supported by Argo Workflows"
  exit 1
fi

# Unzip
echo "Extracting binary..."
gunzip "argo-$ARGO_OS-$ARGO_ARCH.gz"

# Make binary executable
chmod +x "argo-$ARGO_OS-$ARGO_ARCH"

# Move binary to path
if [[ $EUID -eq 0 ]] || [[ -w "/usr/local/bin" ]]; then
  echo "Installing to /usr/local/bin/argo..."
  mv "./argo-$ARGO_OS-$ARGO_ARCH" "/usr/local/bin/argo$FILE_EXT"
else
  # Create $HOME/bin if it doesn't exist
  mkdir -p "$HOME/bin"
  echo "Installing to $HOME/bin/argo..."
  mv "./argo-$ARGO_OS-$ARGO_ARCH" "$HOME/bin/argo$FILE_EXT"

  # Check if $HOME/bin is in PATH and warn if not
  if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
    echo ""
    echo "Warning: $HOME/bin is not in your PATH."
    echo "Add the following line to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
    echo "export PATH=\"\$HOME/bin:\$PATH\""
    echo ""
  fi
fi

# Test installation
argo version
