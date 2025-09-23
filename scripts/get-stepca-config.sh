#!/usr/bin/env bash
NS=step-system
echo "Your CA Password: "
kubectl get -n "$NS" -o jsonpath='{.data.password}' secret/step-ca-step-certificates-ca-password | base64 --decode
echo
echo "Your Provisioner Password: "
kubectl get -n "$NS" -o jsonpath='{.data.password}' secret/step-ca-step-certificates-provisioner-password | base64 --decode
echo
echo "Fingerprint and other info: "
kubectl -n "$NS" logs job.batch/step-ca
kubectl -n "$NS" delete job.batch/step-ca

