#!/usr/bin/env bash

SCRIPT_IS_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  SCRIPT_IS_SOURCED=1
fi

ORIGINAL_SHELL_OPTIONS="$(set +o)"
restore_shell_options() {
  if [[ "${SCRIPT_IS_SOURCED}" -eq 1 ]]; then
    eval "${ORIGINAL_SHELL_OPTIONS}"
  fi
}

trap restore_shell_options EXIT

set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${ROOT_DIR}/phase2-$(date +%s).log"

# Redirect stdout and stderr to both terminal and log file
exec > >(tee -a "${LOG_FILE}")
exec 2>&1

echo "Log file: ${LOG_FILE}"
SECRETS_DIR="${ROOT_DIR}/helm/oauth2-proxy/secrets"
SECRETS_FILE="${SECRETS_DIR}/values.yaml"
ENCRYPTED_FILE="${SECRETS_FILE}.enc"

if ! command -v gpg >/dev/null 2>&1; then
  echo "gpg is required" >&2
  exit 1
fi

if ! command -v sops >/dev/null 2>&1; then
  echo "sops is required (https://github.com/getsops/sops)" >&2
  exit 1
fi

if ! helm plugin list | awk '{print $1}' | grep -qx "secrets"; then
  echo "helm-secrets plugin is required. Run: ./scripts/phase1_bootstrap.sh" >&2
  exit 1
fi

mkdir -p "${SECRETS_DIR}"

mapfile -t SECRET_KEYS < <(gpg --list-secret-keys --keyid-format=long 2>/dev/null | awk '/^sec/{gsub(".*/", "", $2); print $2}')

DEFAULT_KEY_ID=""
if (( ${#SECRET_KEYS[@]} > 0 )); then
  DEFAULT_KEY_ID="${SECRET_KEYS[0]}"
  echo "Found existing GPG secret key(s):"
  for k in "${SECRET_KEYS[@]}"; do
    echo "  - ${k}"
  done

  read -r -p "Use an existing key? [Y/n]: " USE_EXISTING_KEY
  USE_EXISTING_KEY="${USE_EXISTING_KEY:-Y}"
else
  USE_EXISTING_KEY="n"
fi

if [[ "${USE_EXISTING_KEY}" =~ ^[Nn]$ ]]; then
  read -r -p "Name for new GPG key: " GPG_NAME
  read -r -p "Email for new GPG key: " GPG_EMAIL

  if [[ -z "${GPG_NAME}" || -z "${GPG_EMAIL}" ]]; then
    echo "Name and email are required to generate a GPG key." >&2
    exit 1
  fi

  echo "Creating a new GPG key for helm-secrets."
  echo "Enter passphrase for the new key (leave empty for no passphrase)."
  read -r -s -p "New GPG key passphrase: " NEW_KEY_PASSPHRASE
  echo

  set +e
  gpg --batch --pinentry-mode loopback --passphrase "${NEW_KEY_PASSPHRASE}" \
    --quick-generate-key "${GPG_NAME} (helm-secrets) <${GPG_EMAIL}>" default default 0
  GPG_GENERATE_STATUS=$?
  set -e

  if [[ "${GPG_GENERATE_STATUS:-0}" -ne 0 ]]; then
    echo "Warning: gpg returned status ${GPG_GENERATE_STATUS}; verifying key creation before continuing."
  fi

  DEFAULT_KEY_ID="$(gpg --list-secret-keys --with-colons --keyid-format=long 2>/dev/null | awk -F: -v email="${GPG_EMAIL}" '
    $1=="sec" {kid=$5}
    $1=="uid" && index($10, email) {print kid; exit}
  ')"
  if [[ -z "${DEFAULT_KEY_ID}" ]]; then
    DEFAULT_KEY_ID="$(gpg --list-secret-keys --keyid-format=long 2>/dev/null | awk '/^sec/{gsub(".*/", "", $2); print $2; exit}')"
  fi
fi

if [[ -z "${DEFAULT_KEY_ID}" ]]; then
  echo "No GPG secret key found and key generation failed." >&2
  exit 1
fi

read -r -p "PGP key ID [${DEFAULT_KEY_ID}]: " INPUT_KEY_ID
KEY_ID="${INPUT_KEY_ID:-${DEFAULT_KEY_ID}}"

read -r -p "GitHub OAuth Client ID: " GITHUB_CLIENT_ID
read -r -s -p "GitHub OAuth Client Secret: " GITHUB_CLIENT_SECRET
echo

# oauth2-proxy requires cookie_secret to be exactly 16, 24, or 32 bytes.
COOKIE_SECRET="$(openssl rand -hex 16)"
if [[ ${#COOKIE_SECRET} -ne 32 ]]; then
  echo "Failed to generate a valid 32-byte cookie secret" >&2
  exit 1
fi
LB_HOSTNAME="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
if [[ -z "${LB_HOSTNAME}" ]]; then
  echo "Could not detect ingress hostname. Is phase 1 installed?" >&2
  exit 1
fi
PUBLIC_HOST="${PUBLIC_HOST:-${LB_HOSTNAME}}"

cat > "${ROOT_DIR}/.helm-secrets.yaml" <<EOF
cipher: gpg
backend: sops
gpg:
  recipient: ${KEY_ID}
EOF

cat > "${ROOT_DIR}/.sops.yaml" <<EOF
creation_rules:
  - path_regex: helm/.*/secrets/.*\\.ya?ml$
    pgp: "${KEY_ID}"
EOF

cat > "${SECRETS_FILE}" <<EOF
github:
  clientId: "${GITHUB_CLIENT_ID}"
  clientSecret: "${GITHUB_CLIENT_SECRET}"

oauth2Proxy:
  cookieSecret: "${COOKIE_SECRET}"
  emailDomain: "*"
  cookieSecure: false
EOF

# Ensure the encrypted file is regenerated with the selected key.
rm -f "${ENCRYPTED_FILE}"
sops --encrypt --pgp "${KEY_ID}" --output "${ENCRYPTED_FILE}" "${SECRETS_FILE}"
rm -f "${SECRETS_FILE}"

if [[ ! -f "${ENCRYPTED_FILE}" ]]; then
  echo "Expected encrypted file not found: ${ENCRYPTED_FILE}" >&2
  exit 1
fi

helm secrets upgrade --install oauth2-proxy "${ROOT_DIR}/helm/oauth2-proxy" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f "${ENCRYPTED_FILE}" \
  --set ingress.host="${PUBLIC_HOST}"

# Secret changes do not always trigger pod restart automatically.
kubectl -n "${NAMESPACE}" rollout restart deploy/oauth2-proxy
kubectl -n "${NAMESPACE}" rollout status deploy/oauth2-proxy --timeout=300s

helm upgrade --install frontend "${ROOT_DIR}/helm/frontend" \
  --namespace "${NAMESPACE}" \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set ingress.hosts[0].host="${PUBLIC_HOST}" \
  --set ingress.hosts[0].paths[0].path="/" \
  --set ingress.hosts[0].paths[0].pathType="Prefix" \
  --set ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-url="http://${PUBLIC_HOST}/oauth2/auth" \
  --set ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-signin="http://${PUBLIC_HOST}/oauth2/start?rd=\$escaped_request_uri"

helm upgrade --install backend "${ROOT_DIR}/helm/backend" \
  --namespace "${NAMESPACE}" \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set ingress.hosts[0].host="${PUBLIC_HOST}" \
  --set ingress.hosts[0].paths[0].path="/api" \
  --set ingress.hosts[0].paths[0].pathType="Prefix" \
  --set ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-url="http://${PUBLIC_HOST}/oauth2/auth" \
  --set ingress.annotations.nginx\\.ingress\\.kubernetes\\.io/auth-signin="http://${PUBLIC_HOST}/oauth2/start?rd=\$escaped_request_uri"

cat <<EOF

Phase 2 complete.
OAuth2 protection enabled for frontend and backend.

Try:
  curl -i http://${PUBLIC_HOST}/
  curl -i http://${PUBLIC_HOST}/api

Expected: 302 redirect to /oauth2/start when unauthenticated.
Browser URL:
  http://${PUBLIC_HOST}
EOF
