#!/usr/bin/env bash
cd ./workspace-setup || exit
../build-tag-push.sh
cd ..
kubectl create -f jobs/workspace-setup.job.yaml -o jsonpath='{.metadata.name}'
