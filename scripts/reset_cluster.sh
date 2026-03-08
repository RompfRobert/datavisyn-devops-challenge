#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_FILE="${ROOT_DIR}/cluster-reset-$(date +%s).log"

exec > >(tee -a "${LOG_FILE}")
exec 2>&1

echo "Log file: ${LOG_FILE}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd kubectl

if ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
  echo "kubectl cannot reach the current cluster context." >&2
  exit 1
fi

delete_cluster_if_exists() {
  local resource="$1"
  local name="$2"

  if kubectl get "${resource}" "${name}" >/dev/null 2>&1; then
    kubectl delete "${resource}" "${name}" --ignore-not-found --timeout=120s
  fi
}

delete_namespace_if_exists() {
  local namespace="$1"

  if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    kubectl delete namespace "${namespace}" --ignore-not-found --timeout=180s || true
  fi
}

crd_exists() {
  kubectl get crd "$1" >/dev/null 2>&1
}

echo "This will remove the GitOps stack and related cluster-scoped resources."
echo "Namespaces: argocd, demo, ingress-nginx, external-dns, cert-manager"
read -r -p "Continue? [y/N]: " CONFIRM_RESET
if [[ ! "${CONFIRM_RESET:-N}" =~ ^[Yy]$ ]]; then
  echo "Reset cancelled."
  exit 0
fi

echo ""
echo "Removing Argo CD Applications and their finalizers..."
if crd_exists applications.argoproj.io; then
  while IFS= read -r app; do
    [[ -z "${app}" ]] && continue
    kubectl -n argocd patch application "${app}" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done < <(kubectl -n argocd get applications.argoproj.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  kubectl -n argocd delete applications.argoproj.io --all --ignore-not-found --timeout=180s || true
fi

echo "Removing bootstrap resources..."
delete_cluster_if_exists clusterissuer letsencrypt-dns
delete_cluster_if_exists ingressclass nginx

echo "Removing namespaces..."
for namespace in demo ingress-nginx external-dns cert-manager argocd; do
  delete_namespace_if_exists "${namespace}"
done

echo "Removing webhook configurations..."
for resource in mutatingwebhookconfiguration validatingwebhookconfiguration; do
  delete_cluster_if_exists "${resource}" cert-manager-webhook
  delete_cluster_if_exists "${resource}" ingress-nginx-admission
done

echo "Removing cert-manager API service..."
delete_cluster_if_exists apiservice v1beta1.webhook.cert-manager.io

echo "Removing cluster-scoped RBAC..."
for resource in clusterrole clusterrolebinding; do
  delete_cluster_if_exists "${resource}" ingress-nginx
  delete_cluster_if_exists "${resource}" ingress-nginx-admission
  delete_cluster_if_exists "${resource}" external-dns
  delete_cluster_if_exists "${resource}" argocd-application-controller
  delete_cluster_if_exists "${resource}" argocd-applicationset-controller
  delete_cluster_if_exists "${resource}" argocd-server
  delete_cluster_if_exists "${resource}" argocd-notifications-controller
  delete_cluster_if_exists "${resource}" cert-manager-cainjector
  delete_cluster_if_exists "${resource}" cert-manager-controller-approve:cert-manager.io
  delete_cluster_if_exists "${resource}" cert-manager-controller-certificates
  delete_cluster_if_exists "${resource}" cert-manager-controller-challenges
  delete_cluster_if_exists "${resource}" cert-manager-controller-clusterissuers
  delete_cluster_if_exists "${resource}" cert-manager-controller-ingress-shim
  delete_cluster_if_exists "${resource}" cert-manager-controller-issuers
  delete_cluster_if_exists "${resource}" cert-manager-controller-orders
  delete_cluster_if_exists "${resource}" cert-manager-edit
  delete_cluster_if_exists "${resource}" cert-manager-view
done

echo "Removing CRDs..."
for crd in \
  applications.argoproj.io \
  applicationsets.argoproj.io \
  appprojects.argoproj.io \
  argocdextensions.argoproj.io \
  certificaterequests.cert-manager.io \
  certificates.cert-manager.io \
  challenges.acme.cert-manager.io \
  clusterissuers.cert-manager.io \
  issuers.cert-manager.io \
  orders.acme.cert-manager.io
do
  delete_cluster_if_exists crd "${crd}"
done

echo "Waiting for namespaces to terminate..."
for namespace in demo ingress-nginx external-dns cert-manager argocd; do
  kubectl wait --for=delete namespace/"${namespace}" --timeout=180s >/dev/null 2>&1 || true
done

echo ""
echo "Reset complete."
echo "Remaining non-system namespaces:"
kubectl get ns --no-headers 2>/dev/null | awk '$1 !~ /^(default|kube-node-lease|kube-public|kube-system)$/ {print "  - " $1}' || true
