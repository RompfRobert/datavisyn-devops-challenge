#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${ROOT_DIR}/phase1-$(date +%s).log"

# Redirect stdout and stderr to both terminal and log file
exec > >(tee -a "${LOG_FILE}")
exec 2>&1

on_error() {
  local exit_code=$?
  echo ""
  echo "Phase 1 failed with exit code ${exit_code}."
  echo "Check log: ${LOG_FILE}"
  if [[ -t 0 ]]; then
    echo "Press Enter to exit..."
    read -r
  fi
  exit "${exit_code}"
}

trap on_error ERR

echo "Log file: ${LOG_FILE}"

# Ensure helm-secrets plugin is present for phase 2.
if ! helm plugin list | awk '{print $1}' | grep -qx "secrets"; then
  helm plugin install https://github.com/jkroepke/helm-secrets
fi

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo update >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  -f "${ROOT_DIR}/helm/ingress-nginx-values.yaml"

echo "Waiting for ingress controller deployment to become ready..."
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s

echo "Waiting for ingress admission endpoints..."
for _ in $(seq 1 60); do
  ADMISSION_READY="$(kubectl -n ingress-nginx get endpoints ingress-nginx-controller-admission -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
  if [[ -n "${ADMISSION_READY}" ]]; then
    break
  fi
  sleep 5
done

if [[ -z "${ADMISSION_READY:-}" ]]; then
  echo "Ingress admission endpoints not ready in time" >&2
  exit 1
fi

echo "Waiting for ingress-nginx external hostname..."
LB_HOSTNAME=""
for _ in $(seq 1 60); do
  LB_HOSTNAME="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -n "${LB_HOSTNAME}" ]]; then
    break
  fi
  sleep 10
done

if [[ -z "${LB_HOSTNAME}" ]]; then
  echo "Failed to get ingress-nginx LoadBalancer hostname" >&2
  exit 1
fi

PUBLIC_HOST="${PUBLIC_HOST:-${LB_HOSTNAME}}"

helm upgrade --install backend "${ROOT_DIR}/helm/backend" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set ingress.hosts[0].host="${PUBLIC_HOST}" \
  --set ingress.hosts[0].paths[0].path="/api" \
  --set ingress.hosts[0].paths[0].pathType="Prefix"

helm upgrade --install frontend "${ROOT_DIR}/helm/frontend" \
  --namespace "${NAMESPACE}" \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set ingress.hosts[0].host="${PUBLIC_HOST}" \
  --set ingress.hosts[0].paths[0].path="/" \
  --set ingress.hosts[0].paths[0].pathType="Prefix"

cat <<EOF

Phase 1 complete.
Public host:
  ${PUBLIC_HOST}

Use these URLs when creating the GitHub OAuth App:
  Homepage URL: http://${PUBLIC_HOST}
  Callback URL: http://${PUBLIC_HOST}/oauth2/callback

Current app checks (without OAuth protection yet):
  curl -i http://${PUBLIC_HOST}/
  curl -i http://${PUBLIC_HOST}/api
  # Browser: http://${PUBLIC_HOST}

Next step after GitHub OAuth app creation:
  ./scripts/phase2_enable_oauth.sh
EOF

trap - ERR
