#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
PURGE_LOCAL="false"

for arg in "$@"; do
  case "$arg" in
    --purge-local)
      PURGE_LOCAL="true"
      ;;
    --help|-h)
      cat <<EOF
Usage: $(basename "$0") [--purge-local]

Removes all Kubernetes resources created by:
  - scripts/phase1_bootstrap.sh
  - scripts/phase2_enable_oauth.sh

Environment variables:
  NAMESPACE          Application namespace (default: demo)
  INGRESS_NAMESPACE  Ingress namespace (default: ingress-nginx)

Options:
  --purge-local      Also remove locally generated secret/config files
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required" >&2
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "helm is required" >&2
  exit 1
fi

echo "Removing Helm releases from namespace: ${NAMESPACE}"
for release in oauth2-proxy frontend backend; do
  if helm status "$release" -n "$NAMESPACE" >/dev/null 2>&1; then
    helm uninstall "$release" -n "$NAMESPACE"
    echo "  Uninstalled: ${release}"
  else
    echo "  Not installed (skip): ${release}"
  fi
done

echo "Removing ingress-nginx release from namespace: ${INGRESS_NAMESPACE}"
if helm status ingress-nginx -n "$INGRESS_NAMESPACE" >/dev/null 2>&1; then
  helm uninstall ingress-nginx -n "$INGRESS_NAMESPACE"
  echo "  Uninstalled: ingress-nginx"
else
  echo "  Not installed (skip): ingress-nginx"
fi

# Namespace deletion ensures all namespaced resources from both phases are gone.
for ns in "$NAMESPACE" "$INGRESS_NAMESPACE"; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    kubectl delete namespace "$ns" --wait=true
    echo "  Deleted namespace: ${ns}"
  else
    echo "  Namespace not found (skip): ${ns}"
  fi
done

if [[ "$PURGE_LOCAL" == "true" ]]; then
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  rm -f "${ROOT_DIR}/.helm-secrets.yaml"
  rm -f "${ROOT_DIR}/.sops.yaml"
  rm -f "${ROOT_DIR}/helm/oauth2-proxy/secrets/values.yaml"
  rm -f "${ROOT_DIR}/helm/oauth2-proxy/secrets/values.yaml.enc"
  echo "Local generated secrets/config files removed."
fi

cat <<EOF

Cluster reset complete.

Removed (if present):
  - Helm release: backend (${NAMESPACE})
  - Helm release: frontend (${NAMESPACE})
  - Helm release: oauth2-proxy (${NAMESPACE})
  - Helm release: ingress-nginx (${INGRESS_NAMESPACE})
  - Namespace: ${NAMESPACE}
  - Namespace: ${INGRESS_NAMESPACE}

Optional local cleanup can be done with:
  $(basename "$0") --purge-local
EOF
