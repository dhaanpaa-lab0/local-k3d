#!/bin/bash

# Script to enter the dev-shell container
# This script connects to the dev-shell deployment pod and opens an interactive bash session

set -e

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed or not in PATH"
    exit 1
fi

# Check if the current context is correct
CURRENT_CONTEXT=$(kubectl config current-context)
if [[ "$CURRENT_CONTEXT" != "k3d-lk3d-cluster" ]]; then
    echo "Warning: Current kubectl context is '$CURRENT_CONTEXT', expected 'k3d-lk3d-cluster'"
    echo "Switch context? (y/n)"
    read -r response
    if [[ "$response" == "y" || "$response" == "Y" ]]; then
        kubectl config use-context k3d-lk3d-cluster
    else
        echo "Continuing with current context..."
    fi
fi

# Get the dev-shell pod name
echo "Finding dev-shell pod..."
POD_NAME=$(kubectl get pods -l app=dev-shell -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$POD_NAME" ]]; then
    echo "Error: No dev-shell pod found. Make sure the dev-shell deployment is running."
    echo "You can check with: kubectl get pods -l app=dev-shell"
    exit 1
fi

echo "Connecting to pod: $POD_NAME"
echo "Type 'exit' to leave the shell session"
echo ""

# Execute interactive bash session in the dev-shell container
kubectl exec -it "$POD_NAME" -- /bin/bash
