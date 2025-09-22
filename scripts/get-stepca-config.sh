#!/usr/bin/env bash
echo "Your CA Password: "
kubectl get -n step-system -o jsonpath='{.data.password}' secret/step-ca-step-certificates-ca-password | base64 --decode
echo
echo "Your Provisioner Password: "
kubectl get -n step-system -o jsonpath='{.data.password}' secret/step-ca-step-certificates-provisioner-password | base64 --decode
echo
echo "Fingerprint and other info: "
kubectl -n step-system logs job.batch/step-ca
kubectl -n step-system delete job.batch/step-ca

