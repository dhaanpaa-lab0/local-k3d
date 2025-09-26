#!/usr/bin/env bash
# Namespace where you installed step-certificates; default is "default"
NS=step-system
CA_URL_RAW=$(kubectl get --namespace=$NS configmaps step-ca-step-certificates-config -o json | jq -r '.data["defaults.json"]' | jq -r '.["ca-url"]')
# 1) CA URL the chart exposes via service DNS:
CA_URL=${CA_URL_RAW#https://}
echo "Internal CA Url ......... ${CA_URL}"

# 2) Base64-encode the root CA cert for the issuer spec.caBundle:
CA_ROOT_B64=$(kubectl -n $NS \
  get configmap step-ca-step-certificates-certs \
  -o jsonpath="{.data['root_ca\.crt']}" | step base64)

# 3) Provisioner name and kid:
CA_PROVISIONER_NAME="admin"
CA_PROVISIONER_KID=$(kubectl -n $NS \
  get configmap step-ca-step-certificates-config \
  -o jsonpath="{.data['ca\.json']}" | jq -r .authority.provisioners[0].key.kid)

# 4) Reference existing provisioner password secret (created by the chart):
PROV_SECRET_NAME="step-ca-step-certificates-provisioner-password"

# 5) Create a namespaced StepIssuer in (for example) the "default" ns:
cat <<EOF | kubectl apply -f -
apiVersion: certmanager.step.sm/v1beta1
kind: StepIssuer
metadata:
  name: step-issuer
  namespace: step-system
spec:
  url: ${CA_URL}
  caBundle: ${CA_ROOT_B64}
  provisioner:
    name: ${CA_PROVISIONER_NAME}
    kid: ${CA_PROVISIONER_KID}
    passwordRef:
      name: ${PROV_SECRET_NAME}
      key: password

EOF

