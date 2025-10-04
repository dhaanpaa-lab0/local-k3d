#!/bin/bash

# Script to build, push, and deploy containers to local k3d cluster
# Usage: ./build-push-deploy.sh <directory_name>

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REGISTRY_HOST="localhost:5949"
REGISTRY_INTERNAL="lk3d-cluster-registry:5949"
MANIFESTS_DIR="./manifests"

# Function to print colored output
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if directory argument is provided
if [ $# -eq 0 ]; then
    error "Usage: $0 <directory_name>"
    echo "Example: $0 my-app"
    exit 1
fi

DIRECTORY="$1"
IMAGE_NAME="$DIRECTORY"
IMAGE_TAG="latest"
FULL_IMAGE_TAG="${REGISTRY_HOST}/${IMAGE_NAME}:${IMAGE_TAG}"
INTERNAL_IMAGE_TAG="${REGISTRY_INTERNAL}/${IMAGE_NAME}:${IMAGE_TAG}"

# Check if directory exists
if [ ! -d "$DIRECTORY" ]; then
    error "Directory '$DIRECTORY' does not exist"
    exit 1
fi

# Check if Dockerfile exists in the directory
if [ ! -f "$DIRECTORY/Dockerfile" ]; then
    error "No Dockerfile found in directory '$DIRECTORY'"
    exit 1
fi

# Check prerequisites
log "Checking prerequisites..."

# Check if docker is available
if ! command -v docker &> /dev/null; then
    error "Docker is not installed or not in PATH"
    exit 1
fi

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    error "kubectl is not installed or not in PATH"
    exit 1
fi

# Check if we're in the correct kubectl context
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
if [[ "$CURRENT_CONTEXT" != "k3d-lk3d-cluster" ]]; then
    warn "Current kubectl context is '$CURRENT_CONTEXT', expected 'lk3d-cluster'"
    echo "Switch to lk3d-cluster context? (y/n)"
    read -r response
    if [[ "$response" == "y" || "$response" == "Y" ]]; then
        kubectl config use-context lk3d-cluster
        log "Switched to lk3d-cluster context"
    else
        error "Please switch to the correct context and try again"
        exit 1
    fi
fi

# Check if local registry is accessible
log "Checking local registry accessibility..."
if ! curl -s "http://${REGISTRY_HOST}/v2/" > /dev/null; then
    error "Local registry at ${REGISTRY_HOST} is not accessible"
    echo "Make sure your k3d cluster is running with the registry"
    exit 1
fi

# Build the Docker image
log "Building Docker image: ${FULL_IMAGE_TAG}"
docker build -t "${FULL_IMAGE_TAG}" "$DIRECTORY"

if [ $? -ne 0 ]; then
    error "Failed to build Docker image"
    exit 1
fi

# Push the image to local registry
log "Pushing image to local registry..."
docker push "${FULL_IMAGE_TAG}"

if [ $? -ne 0 ]; then
    error "Failed to push image to registry"
    exit 1
fi

# Create manifests directory if it doesn't exist
mkdir -p "$MANIFESTS_DIR"

# Check if deployment manifest already exists
DEPLOYMENT_FILE="${MANIFESTS_DIR}/${IMAGE_NAME}.deployment.yaml"

if [ -f "$DEPLOYMENT_FILE" ]; then
    warn "Deployment manifest already exists: $DEPLOYMENT_FILE"
    echo "Do you want to update the image in the existing manifest? (y/n)"
    read -r response
    if [[ "$response" == "y" || "$response" == "Y" ]]; then
        # Update the existing manifest with new image
        log "Updating existing deployment manifest..."
        # Use sed to update the image line
        if grep -q "image:" "$DEPLOYMENT_FILE"; then
            sed -i.bak "s|image:.*|image: ${INTERNAL_IMAGE_TAG}|g" "$DEPLOYMENT_FILE"
            rm "${DEPLOYMENT_FILE}.bak" 2>/dev/null || true
            log "Updated image in $DEPLOYMENT_FILE"
        else
            warn "Could not find 'image:' line in existing manifest"
        fi
    else
        log "Skipping manifest update"
    fi
else
    # Generate new deployment manifest
    log "Generating new deployment manifest: $DEPLOYMENT_FILE"

    cat > "$DEPLOYMENT_FILE" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${IMAGE_NAME}
  labels:
    app: ${IMAGE_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${IMAGE_NAME}
  template:
    metadata:
      labels:
        app: ${IMAGE_NAME}
    spec:
      containers:
      - name: ${IMAGE_NAME}
        image: ${INTERNAL_IMAGE_TAG}
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: "8080"
        resources:
          requests:
            memory: "64Mi"
            cpu: "250m"
          limits:
            memory: "128Mi"
            cpu: "500m"
EOF

    log "Created deployment manifest: $DEPLOYMENT_FILE"
fi

# Apply the deployment
log "Applying deployment to cluster..."
kubectl apply -f "$DEPLOYMENT_FILE"

if [ $? -eq 0 ]; then
    log "✅ Successfully deployed ${IMAGE_NAME}"

    # Show deployment status
    echo ""
    log "Deployment status:"
    kubectl get deployment "$IMAGE_NAME" 2>/dev/null || true

    echo ""
    log "Pods:"
    kubectl get pods -l "app=${IMAGE_NAME}" 2>/dev/null || true

    echo ""
    log "To check logs: kubectl logs -l app=${IMAGE_NAME} -f"
    log "To port-forward: kubectl port-forward deployment/${IMAGE_NAME} 8080:8080"
else
    error "Failed to apply deployment"
    exit 1
fi
