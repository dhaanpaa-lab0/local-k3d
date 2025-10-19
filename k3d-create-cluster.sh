#!/usr/bin/env bash
D=$(pwd)
# Create Local Folders used for k3d cluster
mkdir -pv ./tmp
mkdir -pv ./local
mkdir -pv ./work
mkdir -pv ./shared
mkdir -pv usr-0{0..9}

# Setup file in shared folder
touch "$D/shared/.gitkeep"
# Mount a **directory** from host to all nodes
k3d cluster create lk3d-cluster \
  --agents 2 \
  --servers 1 \
  --registry-create lk3d-cluster-registry:0.0.0.0:5949 \
  --volume "$D/tmp:/host_tmp@all" \
  --volume "$D/local:/host_local@all" \
  --volume "$D/work:/wrk@all" \
  --volume "$D/shared:/shr@all" \
  --volume "$D/usr-00:/usr-00@all" \
  --volume "$D/usr-01:/usr-01@all" \
  --volume "$D/usr-02:/usr-02@all" \
  --volume "$D/usr-03:/usr-03@all" \
  --volume "$D/usr-04:/usr-04@all" \
  --volume "$D/usr-05:/usr-05@all" \
  --volume "$D/usr-06:/usr-06@all" \
  --volume "$D/usr-07:/usr-07@all" \
  --volume "$D/usr-08:/usr-08@all" \
  --volume "$D/usr-09:/usr-09@all"
