#!/usr/bin/env bash
cd ./workspace-setup
../build-tag-push.sh
kubectl create -f jobs/workspace-setup.job.yaml -o jsonpath='{.metadata.name}'
