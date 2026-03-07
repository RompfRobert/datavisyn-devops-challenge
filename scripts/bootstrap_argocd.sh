#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform"
LOG_FILE="${ROOT_DIR}/argocd-bootstrap-$(date +%s).log"
TARGET_REVISION="${ARGOCD_TARGET_REVISION:-$(awk '/targetRevision:/ { print $2; exit }' "${ROOT_DIR}/argocd/root-application.yaml")}"

exec > >(tee -a "${LOG_FILE}")
exec 2>&1

echo "Log file: ${LOG_FILE}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd terraform
require_cmd helm
require_cmd kubectl
require_cmd jq
require_cmd git

if [[ ! -d "${TERRAFORM_DIR}" ]]; then
  echo "Terraform directory not found: ${TERRAFORM_DIR}" >&2
  exit 1
fi

# Read values from Terraform outputs for validation and ArgoCD ingress.
APP_HOST="$(terraform -chdir="${TERRAFORM_DIR}" output -raw app_host)"
ARGOCD_HOST="$(terraform -chdir="${TERRAFORM_DIR}" output -raw argocd_host)"
DELEGATED_ZONE_NAME="$(terraform -chdir="${TERRAFORM_DIR}" output -raw delegated_zone_name)"

# Populate NS_RECORDS in a portable way: prefer bash's mapfile if available,
# otherwise fall back to a POSIX-friendly while-read loop (works on macOS Bash 3).
if command -v mapfile >/dev/null 2>&1; then
  mapfile -t NS_RECORDS < <(terraform -chdir="${TERRAFORM_DIR}" output -json delegated_zone_name_servers | jq -r '.[]')
else
  NS_RECORDS=()
  while IFS= read -r ns; do
    NS_RECORDS+=("$ns")
  done < <(terraform -chdir="${TERRAFORM_DIR}" output -json delegated_zone_name_servers | jq -r '.[]')
fi

echo ""
echo "Route53 delegated subdomain created: ${DELEGATED_ZONE_NAME}"
echo "Add these NS records in Namecheap for host 'challenge':"
for ns in "${NS_RECORDS[@]}"; do
  echo "  - ${ns}"
done
echo ""
read -r -p "Continue after NS delegation is configured (or if already configured)? [y/N]: " CONTINUE_AFTER_NS
if [[ ! "${CONTINUE_AFTER_NS:-N}" =~ ^[Yy]$ ]]; then
  echo "Stopping. Configure Namecheap delegation first, then rerun." >&2
  exit 1
fi

if [[ "${APP_HOST}" != "challenge.rompf.dev" || "${ARGOCD_HOST}" != "argocd.challenge.rompf.dev" ]]; then
  echo "This branch currently ships ArgoCD app manifests for challenge.rompf.dev and argocd.challenge.rompf.dev." >&2
  echo "Terraform outputs are APP_HOST=${APP_HOST}, ARGOCD_HOST=${ARGOCD_HOST}." >&2
  echo "Update argocd/app manifests before continuing." >&2
  exit 1
fi

# No longer collecting Let's Encrypt email or app OAuth secrets here; managed via Git + SOPS.
if [[ -z "${ARGOCD_GITHUB_CLIENT_ID:-}" ]]; then
  read -r -p "ArgoCD GitHub OAuth Client ID: " ARGOCD_GITHUB_CLIENT_ID
fi
if [[ -z "${ARGOCD_GITHUB_CLIENT_SECRET:-}" ]]; then
  read -r -s -p "ArgoCD GitHub OAuth Client Secret: " ARGOCD_GITHUB_CLIENT_SECRET
  echo
fi
if [[ -z "${GITHUB_ORG:-}" ]]; then
  read -r -p "Optional GitHub org restriction for ArgoCD login (leave empty for none): " GITHUB_ORG
fi

if [[ -z "${ARGOCD_GITHUB_CLIENT_ID}" || -z "${ARGOCD_GITHUB_CLIENT_SECRET}" ]]; then
  echo "ArgoCD GitHub OAuth credentials must be provided." >&2
  exit 1
fi

# SOPS / AGE key for Argo CD repo-server
if [[ -z "${AGE_KEY_FILE:-}" ]]; then
  read -r -p "Path to AGE private key for SOPS decryption (e.g., ./age.agekey): " AGE_KEY_FILE
fi
if [[ ! -f "${AGE_KEY_FILE}" ]]; then
  echo "AGE key file not found: ${AGE_KEY_FILE}" >&2
  exit 1
fi

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

if ! git ls-remote --heads https://github.com/RompfRobert/datavisyn-devops-challenge.git "${TARGET_REVISION}" | grep -q "refs/heads/${TARGET_REVISION}"; then
  echo "Remote branch '${TARGET_REVISION}' was not found on GitHub." >&2
  echo "Push your branch first so ArgoCD can resolve targetRevision=${TARGET_REVISION}." >&2
  exit 1
fi

echo "Skipping controller installs; Argo CD will manage them."

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl -n argocd create secret generic sops-age \
  --from-file=age.agekey="${AGE_KEY_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

TMP_ARGO_VALUES="$(mktemp)"
trap 'rm -f "${TMP_ARGO_VALUES}"' EXIT

ARGO_ORG_BLOCK=""
if [[ -n "${GITHUB_ORG}" ]]; then
  ARGO_ORG_BLOCK="
          orgs:
            - name: ${GITHUB_ORG}"
fi

cat > "${TMP_ARGO_VALUES}" <<EOF
server:
  ingress:
    enabled: true
    ingressClassName: nginx
    hostname: ${ARGOCD_HOST}
    tls: true
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-dns
      nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"

configs:
  params:
    server.insecure: "false"
  rbac:
    policy.default: role:readonly
    policy.csv: |
      g, RompfRobert, role:admin
      g, https://github.com/RompfRobert, role:admin
  cm:
    url: https://${ARGOCD_HOST}
    helm.valuesFileSchemes: >-
      secrets+gpg-import,secrets+gpg-import-kubernetes,secrets+age-import,secrets+age-import-kubernetes,secrets,https
    dex.config: |
      connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: \$dex.github.clientID
          clientSecret: \$dex.github.clientSecret
${ARGO_ORG_BLOCK}
  secret:
    createSecret: true
    extra:
      dex.github.clientID: "${ARGOCD_GITHUB_CLIENT_ID}"
      dex.github.clientSecret: "${ARGOCD_GITHUB_CLIENT_SECRET}"
repoServer:
  env:
    - name: SOPS_AGE_KEY_FILE
      value: /var/run/argocd/sops/age.agekey
    - name: HELM_SECRETS_BACKEND
      value: sops
    - name: HELM_SECRETS_SOPS_PATH
      value: /custom-tools/sops
    - name: HELM_SECRETS_WRAPPER_ENABLED
      value: "true"
    - name: HELM_PLUGINS
      value: /helm-plugins
    - name: PATH
      value: /custom-tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  volumes:
    - name: sops-age
      secret:
        secretName: sops-age
    - name: custom-tools
      emptyDir: {}
    - name: helm-plugins
      emptyDir: {}
  volumeMounts:
    - name: sops-age
      mountPath: /var/run/argocd/sops
      readOnly: true
    - name: custom-tools
      mountPath: /custom-tools
    - name: helm-plugins
      mountPath: /helm-plugins
  initContainers:
    - name: setup-helm-secrets
      image: alpine/helm:3.17.3
      env:
        - name: HELM_PLUGINS
          value: /helm-plugins
      command: ["/bin/sh","-c"]
      args:
        - |
          set -eu
          apk add --no-cache curl git bash
          curl -L -o /custom-tools/sops https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64
          chmod +x /custom-tools/sops
          helm plugin install --verify=false https://github.com/jkroepke/helm-secrets --version v4.7.5
EOF

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  -f "${TMP_ARGO_VALUES}"

kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-dex-server --timeout=300s

kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${ROOT_DIR}/argocd/root-application.yaml"

echo ""
echo "Bootstrap complete."
echo "App host: https://${APP_HOST}"
echo "ArgoCD host: https://${ARGOCD_HOST}"
echo "Remember to keep helm/oauth2-proxy/secrets/values.sops.yaml encrypted with the AGE key provided here."
echo "ArgoCD admin password command:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
