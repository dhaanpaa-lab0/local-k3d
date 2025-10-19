#!/usr/bin/env bash
if [ ! -f Dockerfile ]; then
  echo "Dockerfile not found"
  exit 1
fi
REGISTRY_HOST="localhost:5949"
IMG="$(basename "$(pwd)"):latest"
IMG_REG_TAG="$REGISTRY_HOST/$IMG"
echo "Image: $IMG"
docker build -t "$IMG" .
docker tag  "$IMG" "$IMG_REG_TAG"
docker push "$IMG_REG_TAG"

