#!/usr/bin/env bash
NS=step-system

if [ -d ./tmp ]; then
  echo "Temp Folder Found"
fi
kubectl get -n "$NS" -o jsonpath="{.data['root_ca\.crt']}" configmaps/step-ca-step-certificates-certs | tee ./tmp/root_ca.crt
kubectl get -n "$NS" -o jsonpath="{.data['intermediate_ca\.crt']}" configmaps/step-ca-step-certificates-certs | tee ./tmp/intermediate_ca.crt

