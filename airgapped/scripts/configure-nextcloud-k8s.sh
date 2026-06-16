#!/usr/bin/env bash
# =============================================================================
# Configure an existing Kubernetes Nextcloud to use the local App Store
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/../../"

# Load .env from project root if present
if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

APPSTORE_API_URL="${APPSTORE_API_URL:-https://appstore.local/api/v1}"
NC_NAMESPACE="${NEXTCLOUD_K8S_NAMESPACE:-nextcloud}"
NC_SELECTOR="${NEXTCLOUD_K8S_POD_SELECTOR:-app=nextcloud}"
NC_CONTAINER="${NEXTCLOUD_K8S_CONTAINER:-nextcloud}"

echo "=============================================="
echo "Configure Kubernetes Nextcloud → Local App Store"
echo "=============================================="
echo "Namespace  : ${NC_NAMESPACE}"
echo "Selector   : ${NC_SELECTOR}"
echo "Container  : ${NC_CONTAINER}"
echo "API URL    : ${APPSTORE_API_URL}"
echo ""

# Find the Nextcloud pod
NC_POD="$(kubectl get pod -l "${NC_SELECTOR}" -n "${NC_NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [ -z "${NC_POD}" ]; then
    echo "ERROR: No pod found with selector '${NC_SELECTOR}' in namespace '${NC_NAMESPACE}'"
    echo ""
    echo "Set NEXTCLOUD_K8S_NAMESPACE and NEXTCLOUD_K8S_POD_SELECTOR to match your deployment."
    echo "Example:"
    echo "  NEXTCLOUD_K8S_NAMESPACE=production"
    echo "  NEXTCLOUD_K8S_POD_SELECTOR=app.kubernetes.io/name=nextcloud"
    exit 1
fi

echo "Found Nextcloud pod: ${NC_POD}"
echo ""

echo "Enabling App Store and setting URL..."
kubectl exec "${NC_POD}" -n "${NC_NAMESPACE}" -c "${NC_CONTAINER}" -- \
    sudo -u www-data php occ config:system:set appstoreenabled --value=true --type=boolean

kubectl exec "${NC_POD}" -n "${NC_NAMESPACE}" -c "${NC_CONTAINER}" -- \
    sudo -u www-data php occ config:system:set appstoreurl --value="${APPSTORE_API_URL}"

echo ""
echo "Verifying configuration..."
kubectl exec "${NC_POD}" -n "${NC_NAMESPACE}" -c "${NC_CONTAINER}" -- \
    sudo -u www-data php occ config:system:get appstoreurl

echo ""
# TLS trust guidance
CA_CERT="${PROJECT_DIR}/k8s/certs/root-ca.crt"
if [ -f "${CA_CERT}" ]; then
    echo "--- TLS Trust (self-signed CA detected) ---"
    echo "To trust the App Store CA inside Nextcloud, inject the CA cert via ConfigMap:"
    echo ""
    echo "  kubectl create configmap appstore-ca \\"
    echo "    --from-file=appstore-root-ca.crt=${CA_CERT} \\"
    echo "    -n ${NC_NAMESPACE}"
    echo ""
    echo "Then mount it in your Nextcloud deployment:"
    echo "  volumeMounts:"
    echo "    - name: appstore-ca"
    echo "      mountPath: /usr/local/share/ca-certificates/appstore-root-ca.crt"
    echo "      subPath: appstore-root-ca.crt"
    echo "  volumes:"
    echo "    - name: appstore-ca"
    echo "      configMap:"
    echo "        name: appstore-ca"
    echo ""
    echo "Then run update-ca-certificates inside the pod:"
    echo "  kubectl exec ${NC_POD} -n ${NC_NAMESPACE} -- update-ca-certificates"
    echo ""
fi

echo "=============================================="
echo "Nextcloud configured successfully."
echo "=============================================="
echo ""
echo "Validate:"
echo "  kubectl exec ${NC_POD} -n ${NC_NAMESPACE} -- sudo -u www-data php occ config:system:get appstoreurl"
echo "  kubectl exec ${NC_POD} -n ${NC_NAMESPACE} -- sudo -u www-data php occ app:list"
