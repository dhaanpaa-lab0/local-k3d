local-k3d: Spin up a local k3d cluster with Argo Workflows and Traefik ingress

Overview
- This repo provides a set of scripts to quickly create a local Kubernetes cluster using k3d, install Argo Workflows, expose the Argo UI through Traefik, and create an admin ServiceAccount for UI/CLI access.
- Default host/ports for the Argo UI via Traefik: http://argo.localtest.me:8281
- Everything is intended for local development only.

Prerequisites
- Container runtime: Docker Desktop or Colima (with Docker CLI)
- k3d installed and available in PATH: https://k3d.io/
- kubectl installed and available in PATH
- helm installed and available in PATH: https://helm.sh/
- curl and gunzip (gzip) for CLI downloads
- macOS users (optional): Homebrew to simplify installing dependencies and the argo CLI

Optional: install tools via Brewfile (macOS)
- From the repo root: brew bundle

Quick start (script order)
1) Create the k3d cluster
   bash scripts/install-k3d.sh
   Notes:
   - Exposes Traefik HTTP on host 8281 -> cluster LB 80
   - Exposes Traefik HTTPS on host 8443 -> cluster LB 443
   - Exposes Kubernetes API on host 6550

2) Install Argo Workflows (and the argo CLI if needed)
   bash scripts/install-argo.sh
   - Installs Argo Workflows into the argo namespace (can override ARGO_NS)
   - Waits for argo-server and workflow-controller to be ready

3) Expose the Argo UI via Traefik Ingress (optional but recommended)
   bash scripts/setup-argo-ingress.sh
   - Applies k8s/argo-ui-ingress.yaml (Traefik IngressRoute + ServersTransport)
   - Default UI URL: http://argo.localtest.me:8281
   - To override host: ARGO_INGRESS_HOST=myhost.localtest.me bash scripts/setup-argo-ingress.sh

4) Create an Argo admin ServiceAccount and get a token
   bash scripts/setup-argo-admin.sh
   - Writes instructions and a bearer token to tmp/argo-admin-instructions.txt
   - Use the token to log in to the UI or via the argo CLI

5) Verify with a sample workflow
   argo submit --watch \
     https://raw.githubusercontent.com/argoproj/argo-workflows/v3.5.8/examples/hello-world.yaml \
     -n argo

   Or, use helper scripts that log in with the created ServiceAccount and submit:
   - bash scripts/submit-hello-world.sh
   - bash scripts/submit-workflow.sh <FILE_OR_URL> [--watch]
   These scripts use a bearer token and work across different argo CLI versions (no separate `argo login` step needed).

Access the Argo UI
- If you ran setup-argo-ingress.sh:
  - Open: http://argo.localtest.me:8281 (or your ARGO_INGRESS_HOST + K3D_HTTP_PORT)
  - Log in using the bearer token from tmp/argo-admin-instructions.txt
- Alternatively, port-forward without ingress:
  kubectl -n argo port-forward svc/argo-server 2746:2746
  Then open http://localhost:2746

Cluster lifecycle (start/stop)
- Start an existing cluster without recreating it:
  bash scripts/start-k3d.sh [CLUSTER_NAME]
- Stop a running cluster (keep it for later):
  bash scripts/stop-k3d.sh [CLUSTER_NAME]
Notes:
- Defaults to k3s-default if no name is provided.
- You can also set K3D_CLUSTER env var to target a specific cluster.
- To permanently delete the cluster, use destroy-k3d.sh (see next section).

Tear down
- Delete the k3d cluster:
  bash scripts/destroy-k3d.sh            # deletes the default cluster (k3s-default)
  bash scripts/destroy-k3d.sh mycluster  # deletes a named cluster

Troubleshooting
- Check Traefik logs (routing/UI issues):
  bash scripts/traefik-logs.sh
  bash scripts/traefik-logs.sh -f --since=1h --outfile
- Ensure your kubectl context is set to a k3d context. Most scripts auto-detect, but you can override with K3D_CONTEXT.
- If images pull slowly on first run, components might take a while to become Ready. Scripts use generous rollout timeouts.
- If the UI host doesn’t resolve, localtest.me resolves to 127.0.0.1 automatically. If you choose a different host, add it to /etc/hosts.
- Seeing "Forbidden" when logging into the Argo UI (e.g., Argo v3.7.x)? Re-run: bash scripts/setup-argo-admin.sh. It now configures Argo RBAC (policy.csv) to grant admin to the created ServiceAccount (argo-admin by default). Then log in using the token written to tmp/argo-admin-instructions.txt.
- Using an older argo CLI that lacks --auth-mode/--server flags? The submit-*.sh helper scripts auto-detect capabilities and fall back to compatible modes (including kubectl), so no manual argo login is required.

Environment variables
- Common
  - K3D_CONTEXT: Kubernetes context to use (auto-detected k3d context by default)

- scripts/install-k3d.sh
  - K3D_CLUSTER: Cluster name (default: k3s-default)
  - K3D_AGENTS: Number of agent nodes (default: 2)
  - K3D_API_PORT: Host port for Kubernetes API (default: 6550)
  - K3D_HTTP_PORT: Host port mapped to LB 80 (default: 8281)
  - K3D_HTTPS_PORT: Host port mapped to LB 443 (default: 8443)

- scripts/install-argo.sh
  - ARGO_VERSION: Argo Workflows version (default: v3.5.8)
  - K3D_CONTEXT: Override the kube context
  - ARGO_NS: Namespace (default: argo)

- scripts/setup-argo-ingress.sh
  - K3D_CONTEXT: Override the kube context
  - ARGO_NS: Namespace (default: argo)
  - ARGO_INGRESS_FILE: Path to ingress manifest (default: k8s/argo-ui-ingress.yaml)
  - ARGO_INGRESS_HOST: Hostname for ingress (default inside manifest: argo.localtest.me)
  - K3D_HTTP_PORT: Host HTTP port (default: 8281)

- scripts/setup-argo-admin.sh
  - K3D_CONTEXT: Override the kube context
  - ARGO_NS: Namespace (default: argo)
  - SA_NAME: ServiceAccount name (default: argo-admin)
  - K3D_HTTP_PORT: Host HTTP port (default: 8281)
  - ARGO_INGRESS_HOST: Hostname for UI if using ingress (optional)

- scripts/traefik-logs.sh
  - K3D_CONTEXT: Override the kube context
  - TRAEFIK_NS: Namespace where Traefik runs (default: kube-system)

Kubernetes manifests in this repo
- k8s/argo-ui-ingress.yaml
  - Traefik IngressRoute to expose argo-server on HTTP via the k3d Traefik load balancer
  - Uses a Traefik ServersTransport to skip TLS verification when connecting to argo-server (local dev only)
  - Default host: argo.localtest.me → change via ARGO_INGRESS_HOST or edit the file

Notes
- These scripts are idempotent where possible and safe to re-run.
- All artifacts generated by helper scripts are written under tmp/.
- Do not use these defaults (especially cluster-admin bindings) in production.


ZITADEL on k3d with step-ca and CloudNativePG
- This repo now includes scripts and manifests to deploy ZITADEL locally on k3d using cert-manager with Smallstep step-ca/step-issuer for TLS and CloudNativePG for PostgreSQL.
- See the detailed walk-through: zitadel_k3d_stepca.md

Quick start (ZITADEL)
1) Create the k3d cluster
   bash scripts/install-k3d.sh
   Notes:
   - Exposes Traefik HTTP on host 8281 -> cluster LB 80
   - Exposes Traefik HTTPS on host 8443 -> cluster LB 443

2) Install cert-manager
   bash scripts/install-cert-manager.sh

3) Install step-ca and step-issuer
   bash scripts/install-step-ca.sh
   - Prepare and apply the StepClusterIssuer from a template into tmp/ (auto-discovers values from the cluster). The script now encodes the root CA PEM into base64 for spec.caBundle (required by the CRD):
     bash scripts/setup-step-issuer.sh
     # Fallback/override: STEP_CA_BUNDLE_FILE=path/to/root_ca.pem STEP_PROVISIONER_PASSWORD=... bash scripts/setup-step-issuer.sh

4) Prepare ZITADEL values into tmp/
   - Option A (recommended): ZITADEL_MASTERKEY=$(openssl rand -base64 36) ZITA_HOST=zita.localtest.me bash scripts/prepare-zitadel-values.sh
   - Option B: Edit k8s/zitadel-values.yaml manually and use that file

5) Deploy ZITADEL + CNPG and certificate
   ZITA_VALUES_FILE=tmp/zitadel-values.yaml bash scripts/setup-zitadel.sh

Access ZITADEL
- Open: https://zita.localtest.me:8443
- If you see "Instance not found", ensure ExternalDomain in k8s/zitadel-values.yaml exactly matches zita.localtest.me.

Troubleshooting (ZITADEL)
- Certificate not issued: Check that cert-manager pods are Ready and the StepClusterIssuer is applied with the correct caBundle/password. Inspect the CertificateRequest with: kubectl -n zitadel describe certificaterequest -l app.kubernetes.io/name=zitadel
- Database connectivity: Ensure the CNPG cluster pg-zita is Ready and the service pg-zita-rw.zitadel.svc.cluster.local:5432 is resolvable from the cluster.
- Ports/hostnames: For local development, zita.localtest.me resolves to 127.0.0.1. HTTPS uses host port 8443 mapped to LB 443 by install-k3d.sh, so include :8443 in the URL.

Environment variables (ZITADEL scripts)
- scripts/install-cert-manager.sh
  - K3D_CONTEXT: Optional kube context override
- scripts/install-step-ca.sh
  - K3D_CONTEXT: Optional kube context override
- scripts/setup-zitadel.sh
  - K3D_CONTEXT: Optional kube context override
  - ZITA_NS: Namespace for ZITADEL (default: zitadel)
  - CNPG_NS: Namespace for CloudNativePG operator (default: cnpg-system)
  - ZITA_HOST: External hostname (default: zita.localtest.me)
  - ZITA_VALUES_FILE: Path to Helm values (default: k8s/zitadel-values.yaml)
  - APPLY_CERT: Set to 'false' to skip applying k8s/zita-cert.yaml (default: true)

- scripts/setup-step-issuer.sh
  - Auto-discovers step-ca root CA and provisioner password from the cluster (namespace: step-system) by default.
  - K3D_CONTEXT: Optional kube context override
  - STEP_CA_BUNDLE_FILE: Path to root CA PEM file to inject into caBundle (override)
  - STEP_CA_BUNDLE: Inline PEM content for caBundle (multi-line; override)
  - STEP_PROVISIONER_PASSWORD: Provisioner password for step-ca (override)
  - TEMPLATE_FILE/OUTPUT_FILE: Optional paths to override template/output

- scripts/download-step-root-ca.sh
  - Fetches the step-ca root certificate from the cluster and writes it to tmp/step-root-ca.pem.
  - Auto-discovers across common secret/configmap names and, if needed, scans all resources in the namespace for PEM-looking content.
  - K3D_CONTEXT: Optional kube context override
  - NAMESPACE: Namespace of step-certificates (default: step-system)
  - OUTPUT_FILE: Destination file path (default: tmp/step-root-ca.pem)
  - PRINT_ONLY=1: Print PEM to stdout instead of writing a file

- scripts/prepare-zitadel-values.sh
  - ZITADEL_MASTERKEY: Strong random master key (32+ chars)
  - ZITA_HOST: External hostname applied to values (default: zita.localtest.me)
  - TEMPLATE_FILE/OUTPUT_FILE: Optional paths to override template/output
