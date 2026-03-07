#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
EXTERNAL_DNS_NAMESPACE="${EXTERNAL_DNS_NAMESPACE:-external-dns}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
PURGE_LOCAL="false"
PURGE_CRDS="true"

CERT_MANAGER_CRDS=(
  certificates.cert-manager.io
  certificaterequests.cert-manager.io
  challenges.acme.cert-manager.io
  clusterissuers.cert-manager.io
  issuers.cert-manager.io
  orders.acme.cert-manager.io
)

ARGOCD_CRDS=(
  applications.argoproj.io
  applicationsets.argoproj.io
  appprojects.argoproj.io
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [--purge-local] [--keep-crds]

Removes Kubernetes resources created by this repository, including:
  - scripts/phase1_bootstrap.sh
  - scripts/phase2_enable_oauth.sh
  - scripts/bootstrap_argocd.sh

Environment variables:
  NAMESPACE               Application namespace (default: demo)
  INGRESS_NAMESPACE       ingress-nginx namespace (default: ingress-nginx)
  EXTERNAL_DNS_NAMESPACE  external-dns namespace (default: external-dns)
  CERT_MANAGER_NAMESPACE  cert-manager namespace (default: cert-manager)
  ARGOCD_NAMESPACE        ArgoCD namespace (default: argocd)

Options:
  --purge-local           Remove locally generated secret/config files
  --keep-crds             Keep cert-manager/ArgoCD CRDs (default is to purge)
  --help, -h              Show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --purge-local)
      PURGE_LOCAL="true"
      ;;
    --keep-crds)
      PURGE_CRDS="false"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
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

uninstall_if_exists() {
  local release="$1"
  local ns="$2"
  if helm status "$release" -n "$ns" >/dev/null 2>&1; then
    helm uninstall "$release" -n "$ns"
    echo "  Uninstalled: ${release} (${ns})"
  else
    echo "  Not installed (skip): ${release} (${ns})"
  fi
}

delete_namespace_if_exists() {
  local ns="$1"
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    kubectl delete namespace "$ns" --wait=true
    echo "  Deleted namespace: ${ns}"
  else
    echo "  Namespace not found (skip): ${ns}"
  fi
}

delete_cluster_scoped_if_exists() {
  local kind="$1"
  local name="$2"
  if kubectl get "$kind" "$name" >/dev/null 2>&1; then
    kubectl delete "$kind" "$name"
    echo "  Deleted ${kind}/${name}"
  else
    echo "  Not found (skip): ${kind}/${name}"
  fi
}

echo "Removing cluster-scoped resources"
delete_cluster_scoped_if_exists clusterissuer letsencrypt-dns

echo "Removing ArgoCD application objects (if CRD exists)"
if kubectl api-resources --api-group=argoproj.io | grep -q '^applications'; then
  kubectl -n "$ARGOCD_NAMESPACE" delete applications.argoproj.io --all --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$ARGOCD_NAMESPACE" delete applicationsets.argoproj.io --all --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$ARGOCD_NAMESPACE" delete appprojects.argoproj.io --all --ignore-not-found >/dev/null 2>&1 || true
  echo "  Deleted ArgoCD app resources in namespace: ${ARGOCD_NAMESPACE}"
else
  echo "  ArgoCD CRDs not present (skip app resource cleanup)"
fi

echo "Removing Helm releases"
# Legacy phase1/phase2 releases.
uninstall_if_exists oauth2-proxy "$NAMESPACE"
uninstall_if_exists frontend "$NAMESPACE"
uninstall_if_exists backend "$NAMESPACE"
uninstall_if_exists ingress-nginx "$INGRESS_NAMESPACE"

# ArgoCD bootstrap releases.
uninstall_if_exists external-dns "$EXTERNAL_DNS_NAMESPACE"
uninstall_if_exists cert-manager "$CERT_MANAGER_NAMESPACE"
uninstall_if_exists argocd "$ARGOCD_NAMESPACE"

echo "Deleting namespaces"
delete_namespace_if_exists "$NAMESPACE"
delete_namespace_if_exists "$INGRESS_NAMESPACE"
delete_namespace_if_exists "$EXTERNAL_DNS_NAMESPACE"
delete_namespace_if_exists "$CERT_MANAGER_NAMESPACE"
delete_namespace_if_exists "$ARGOCD_NAMESPACE"

if [[ "$PURGE_CRDS" == "true" ]]; then
  echo "Purging cert-manager and ArgoCD CRDs"
  for crd in "${CERT_MANAGER_CRDS[@]}"; do
    kubectl delete crd "$crd" --ignore-not-found >/dev/null 2>&1 || true
    echo "  Processed CRD: ${crd}"
  done
  for crd in "${ARGOCD_CRDS[@]}"; do
    kubectl delete crd "$crd" --ignore-not-found >/dev/null 2>&1 || true
    echo "  Processed CRD: ${crd}"
  done
else
  echo "Keeping CRDs (--keep-crds was set)"
fi

if [[ "$PURGE_LOCAL" == "true" ]]; then
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # Legacy phase1/phase2 local artifacts.
  rm -f "${ROOT_DIR}/.helm-secrets.yaml"
  rm -f "${ROOT_DIR}/.sops.yaml"
  rm -f "${ROOT_DIR}/helm/oauth2-proxy/secrets/values.yaml"
  rm -f "${ROOT_DIR}/helm/oauth2-proxy/secrets/values.yaml.enc"
  # ArgoCD bootstrap logs and temporary local artifacts.
  rm -f "${ROOT_DIR}"/argocd-bootstrap-*.log
  echo "Local generated secrets/config files removed."
fi

cat <<EOF

Cluster reset complete.

Removed (if present):
  - Helm releases in ${NAMESPACE}: backend, frontend, oauth2-proxy
  - Helm release in ${INGRESS_NAMESPACE}: ingress-nginx
  - Helm release in ${EXTERNAL_DNS_NAMESPACE}: external-dns
  - Helm release in ${CERT_MANAGER_NAMESPACE}: cert-manager
  - Helm release in ${ARGOCD_NAMESPACE}: argocd
  - ClusterIssuer: letsencrypt-dns
  - Namespace: ${NAMESPACE}
  - Namespace: ${INGRESS_NAMESPACE}
  - Namespace: ${EXTERNAL_DNS_NAMESPACE}
  - Namespace: ${CERT_MANAGER_NAMESPACE}
  - Namespace: ${ARGOCD_NAMESPACE}

CRD purge mode: ${PURGE_CRDS}

Optional local cleanup can be done with:
  $(basename "$0") --purge-local
EOF
