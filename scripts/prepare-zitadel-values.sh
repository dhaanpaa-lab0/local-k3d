#!/usr/bin/env bash
set -euo pipefail

# prepare-zitadel-values.sh
# Creates a working Helm values file for ZITADEL under tmp/ from k8s/zitadel-values.yaml,
# allowing you to inject a masterkey and external host via environment variables.
#
# Usage:
#   bash scripts/prepare-zitadel-values.sh
#   ZITADEL_MASTERKEY=$(openssl rand -base64 36) ZITA_HOST=myhost.localtest.me bash scripts/prepare-zitadel-values.sh
#
# Env:
#   ZITADEL_MASTERKEY  Master key (32+ chars recommended). If empty, placeholder remains.
#   ZITA_HOST          External hostname (applied to ExternalDomain and ingress.hosts). Default: zita.localtest.me
#   TEMPLATE_FILE      Optional path to source template (default: k8s/zitadel-values.yaml)
#   OUTPUT_FILE        Optional output path (default: tmp/zitadel-values.yaml)
#
# After running, pass the generated file to setup-zitadel.sh via:
#   ZITA_VALUES_FILE=tmp/zitadel-values.yaml bash scripts/setup-zitadel.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="${TEMPLATE_FILE:-$REPO_ROOT/k8s/zitadel-values.yaml}"
OUTPUT_FILE="${OUTPUT_FILE:-$REPO_ROOT/tmp/zitadel-values.yaml}"
ZITA_HOST="${ZITA_HOST:-zita.localtest.me}"
ZITADEL_MASTERKEY="${ZITADEL_MASTERKEY:-}"

mkdir -p "$REPO_ROOT/tmp"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "[ERROR] Template not found: $TEMPLATE_FILE" >&2
  exit 1
fi

cp "$TEMPLATE_FILE" "$OUTPUT_FILE"

# Substitute masterkey if provided
if [[ -n "$ZITADEL_MASTERKEY" ]]; then
  # Replace the quoted placeholder value
  sed -i.bak "s#\"REPLACE_WITH_32+_RANDOM\"#\"${ZITADEL_MASTERKEY//#/\\#}\"#g" "$OUTPUT_FILE"
  rm -f "$OUTPUT_FILE.bak"
fi

# Update host in all occurrences
# - ExternalDomain: "..."
# - hosts: [ ... ] and the tls.hosts
sed -i.bak \
  -e "s#\(ExternalDomain: \)\".*\"#\1\"${ZITA_HOST//#/\\#}\"#" \
  -e "s#\(- host: \)\".*\"#\1\"${ZITA_HOST//#/\\#}\"#" \
  -e "s#\(hosts: \[\)\".*\"\(\]$\)#\1\"${ZITA_HOST//#/\\#}\"\2#" \
  "$OUTPUT_FILE" || true
rm -f "$OUTPUT_FILE.bak"

echo "[INFO] Wrote ZITADEL values to: $OUTPUT_FILE"
if grep -q 'REPLACE_WITH_32+_RANDOM' "$OUTPUT_FILE"; then
  echo "[WARN] Masterkey placeholder remains. You can rerun with ZITADEL_MASTERKEY=... or edit the file manually." >&2
fi

echo "[HINT] Deploy with: ZITA_VALUES_FILE=$OUTPUT_FILE bash scripts/setup-zitadel.sh"
