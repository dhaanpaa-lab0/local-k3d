#!/usr/bin/env bash
D=$(pwd)
# Create Local Folders used for k3d cluster
mkdir -pv ./tmp
mkdir -pv ./local
mkdir -pv ./work
mkdir -pv ./shared
# Setup file in shared folder
touch "$D/shared/.gitkeep"
# Mount a **directory** from host to all nodes
k3d cluster create lk3d-cluster \
  --agents 2 \
  --servers 1 \
  --registry-create lk3d-cluster-registry:0.0.0.0:5949 \
  --volume "$D/tmp:/ht@all" \
  --volume "$D/local:/hl@all" \
  --volume "$D/work:/wrk@all" \
  --volume "$D/local:/h@all"

