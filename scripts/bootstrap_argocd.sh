#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="${ROOT_DIR}/terraform"
LOG_FILE="${ROOT_DIR}/argocd-bootstrap-$(date +%s).log"

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
require_cmd openssl
require_cmd jq

if [[ ! -d "${TERRAFORM_DIR}" ]]; then
  echo "Terraform directory not found: ${TERRAFORM_DIR}" >&2
  exit 1
fi

# Read values from Terraform outputs so DNS/IAM wiring stays single-source-of-truth.
REGION="$(terraform -chdir="${TERRAFORM_DIR}" output -raw region)"
CLUSTER_NAME="$(terraform -chdir="${TERRAFORM_DIR}" output -raw cluster_name)"
APP_HOST="$(terraform -chdir="${TERRAFORM_DIR}" output -raw app_host)"
ARGOCD_HOST="$(terraform -chdir="${TERRAFORM_DIR}" output -raw argocd_host)"
DELEGATED_ZONE_NAME="$(terraform -chdir="${TERRAFORM_DIR}" output -raw delegated_zone_name)"
DELEGATED_ZONE_ID="$(terraform -chdir="${TERRAFORM_DIR}" output -raw delegated_zone_id)"
EXTERNAL_DNS_ROLE_ARN="$(terraform -chdir="${TERRAFORM_DIR}" output -raw external_dns_role_arn)"
CERT_MANAGER_ROLE_ARN="$(terraform -chdir="${TERRAFORM_DIR}" output -raw cert_manager_role_arn)"

mapfile -t NS_RECORDS < <(terraform -chdir="${TERRAFORM_DIR}" output -json delegated_zone_name_servers | jq -r '.[]')

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

if [[ -z "${LETSENCRYPT_EMAIL:-}" ]]; then
  read -r -p "Let's Encrypt email: " LETSENCRYPT_EMAIL
fi
if [[ -z "${LETSENCRYPT_EMAIL}" ]]; then
  echo "Let's Encrypt email is required." >&2
  exit 1
fi

if [[ -z "${APP_GITHUB_CLIENT_ID:-}" ]]; then
  read -r -p "App GitHub OAuth Client ID: " APP_GITHUB_CLIENT_ID
fi
if [[ -z "${APP_GITHUB_CLIENT_SECRET:-}" ]]; then
  read -r -s -p "App GitHub OAuth Client Secret: " APP_GITHUB_CLIENT_SECRET
  echo
fi
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

if [[ -z "${APP_GITHUB_CLIENT_ID}" || -z "${APP_GITHUB_CLIENT_SECRET}" || -z "${ARGOCD_GITHUB_CLIENT_ID}" || -z "${ARGOCD_GITHUB_CLIENT_SECRET}" ]]; then
  echo "All required OAuth credentials must be provided." >&2
  exit 1
fi

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update >/dev/null

if ! git ls-remote --heads https://github.com/RompfRobert/datavisyn-devops-challenge.git argocd | grep -q 'refs/heads/argocd'; then
  echo "Remote branch 'argocd' was not found on GitHub." >&2
  echo "Push your branch first so ArgoCD can resolve targetRevision=argocd." >&2
  exit 1
fi

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  -f "${ROOT_DIR}/helm/ingress-nginx-values.yaml"

kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s

helm upgrade --install external-dns external-dns/external-dns \
  --namespace external-dns \
  --create-namespace \
  --set provider=aws \
  --set policy=sync \
  --set registry=txt \
  --set txtOwnerId="${CLUSTER_NAME}-external-dns" \
  --set domainFilters[0]="${DELEGATED_ZONE_NAME}" \
  --set sources[0]=ingress \
  --set serviceAccount.create=true \
  --set serviceAccount.name=external-dns \
  --set-string serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn="${EXTERNAL_DNS_ROLE_ARN}"

kubectl -n external-dns rollout status deploy/external-dns --timeout=300s

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --set serviceAccount.create=true \
  --set serviceAccount.name=cert-manager \
  --set-string serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn="${CERT_MANAGER_ROLE_ARN}"

kubectl -n cert-manager rollout status deploy/cert-manager --timeout=300s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=300s

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-dns-account-key
    solvers:
      - dns01:
          route53:
            region: ${REGION}
            hostedZoneID: ${DELEGATED_ZONE_ID}
EOF

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
    policy.default: role:admin
  cm:
    url: https://${ARGOCD_HOST}
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
COOKIE_SECRET="$(openssl rand -hex 16)"

kubectl -n demo create secret generic oauth2-proxy-secret \
  --from-literal=OAUTH2_PROXY_CLIENT_ID="${APP_GITHUB_CLIENT_ID}" \
  --from-literal=OAUTH2_PROXY_CLIENT_SECRET="${APP_GITHUB_CLIENT_SECRET}" \
  --from-literal=OAUTH2_PROXY_COOKIE_SECRET="${COOKIE_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${ROOT_DIR}/argocd/root-application.yaml"

echo ""
echo "Bootstrap complete."
echo "App host: https://${APP_HOST}"
echo "ArgoCD host: https://${ARGOCD_HOST}"
echo "ArgoCD admin password command:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
