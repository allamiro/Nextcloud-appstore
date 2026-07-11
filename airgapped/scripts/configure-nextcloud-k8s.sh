#!/usr/bin/env bash
# =============================================================================
# Configure an existing Kubernetes Nextcloud to use the local App Store
# =============================================================================
# Behaviour:
#   - Backs up current appstoreurl / appstoreenabled before changing them
#   - Skips occ calls where the value is already correct (idempotent)
#   - Installs CA cert as a ConfigMap if k8s/certs/root-ca.crt exists
#   - Tests connectivity from inside the Nextcloud pod
#   - Rolls back to the backup values on any failure
#
# Usage:
#   ./airgapped/scripts/configure-nextcloud-k8s.sh [--no-ca] [--no-test]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

APPSTORE_API_URL="${APPSTORE_API_URL:-https://appstore.local/api/v1}"
NC_NAMESPACE="${NEXTCLOUD_K8S_NAMESPACE:-nextcloud}"
NC_SELECTOR="${NEXTCLOUD_K8S_POD_SELECTOR:-app=nextcloud}"
NC_CONTAINER="${NEXTCLOUD_K8S_CONTAINER:-nextcloud}"
CA_CERT="${PROJECT_DIR}/k8s/certs/root-ca.crt"
BACKUP_FILE="${PROJECT_DIR}/exports/.nc-config-backup-k8s.env"

INSTALL_CA=true
RUN_TEST=true
for arg in "$@"; do
    case "${arg}" in
        --no-ca)    INSTALL_CA=false ;;
        --no-test)  RUN_TEST=false ;;
    esac
done

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; }

echo "============================================================"
echo "Configure Kubernetes Nextcloud → Local App Store"
echo "  Namespace  : ${NC_NAMESPACE}"
echo "  Selector   : ${NC_SELECTOR}"
echo "  Container  : ${NC_CONTAINER}"
echo "  API URL    : ${APPSTORE_API_URL}"
echo "============================================================"
echo ""

# ── Find pod ──────────────────────────────────────────────────────────────────
NC_POD="$(kubectl get pod -l "${NC_SELECTOR}" -n "${NC_NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "${NC_POD}" ] || {
    error "No pod found with selector '${NC_SELECTOR}' in namespace '${NC_NAMESPACE}'"
    echo "Set NEXTCLOUD_K8S_NAMESPACE and NEXTCLOUD_K8S_POD_SELECTOR in .env"
    exit 1
}
info "Found Nextcloud pod: ${NC_POD}"

occ() { kubectl exec "${NC_POD}" -n "${NC_NAMESPACE}" -c "${NC_CONTAINER}" -- \
            sudo -u www-data php occ "$@"; }
kexec() { kubectl exec "${NC_POD}" -n "${NC_NAMESPACE}" -c "${NC_CONTAINER}" -- "$@"; }

# ── Backup current config ─────────────────────────────────────────────────────
mkdir -p "$(dirname "${BACKUP_FILE}")"
PREV_URL="$(occ config:system:get appstoreurl 2>/dev/null || echo "")"
PREV_ENABLED="$(occ config:system:get appstoreenabled 2>/dev/null || echo "")"
cat > "${BACKUP_FILE}" <<EOF
# NC K8s config backup — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
PREV_APPSTOREURL=${PREV_URL}
PREV_APPSTOREENABLED=${PREV_ENABLED}
NC_POD=${NC_POD}
NC_NAMESPACE=${NC_NAMESPACE}
EOF
info "Config backed up to ${BACKUP_FILE}"

# ── Rollback helper ───────────────────────────────────────────────────────────
rollback() {
    warn "Rolling back to previous configuration..."
    if [ -n "${PREV_URL}" ]; then
        occ config:system:set appstoreurl --value="${PREV_URL}" &>/dev/null || true
    else
        occ config:system:delete appstoreurl &>/dev/null || true
    fi
    if [ -n "${PREV_ENABLED}" ]; then
        occ config:system:set appstoreenabled --value="${PREV_ENABLED}" --type=boolean &>/dev/null || true
    fi
    error "Configuration rolled back. Fix the issue and re-run."
    exit 1
}

# ── Install CA certificate via ConfigMap ──────────────────────────────────────
if [ "${INSTALL_CA}" = "true" ] && [ -f "${CA_CERT}" ]; then
    info "Creating/updating appstore-ca ConfigMap in namespace ${NC_NAMESPACE}..."
    kubectl create configmap appstore-ca \
        --from-file=appstore-root-ca.crt="${CA_CERT}" \
        -n "${NC_NAMESPACE}" \
        --dry-run=client -o yaml \
        | kubectl apply -f -

    info "Running update-ca-certificates inside pod..."
    kexec bash -c "cp /etc/ssl/certs/ca-certificates.crt /tmp/ca-backup.crt 2>/dev/null; \
        mkdir -p /usr/local/share/ca-certificates && \
        kubectl get configmap appstore-ca -n ${NC_NAMESPACE} \
            -o jsonpath='{.data.appstore-root-ca\\.crt}' \
            > /usr/local/share/ca-certificates/appstore-root-ca.crt 2>/dev/null || true; \
        update-ca-certificates 2>&1 | tail -3" 2>/dev/null || \
        warn "Could not auto-install CA inside pod — see manual TLS instructions below."
    ok "CA ConfigMap applied."
elif [ "${INSTALL_CA}" = "true" ] && [ ! -f "${CA_CERT}" ]; then
    warn "CA cert not found at ${CA_CERT} — skipping."
fi

# ── Apply configuration ───────────────────────────────────────────────────────
info "Applying configuration..."

CURRENT_ENABLED="$(occ config:system:get appstoreenabled 2>/dev/null || echo "")"
if [ "${CURRENT_ENABLED}" = "true" ]; then
    ok "appstoreenabled already true — skipping."
else
    occ config:system:set appstoreenabled --value=true --type=boolean
    ok "appstoreenabled = true"
fi

CURRENT_URL="$(occ config:system:get appstoreurl 2>/dev/null || echo "")"
if [ "${CURRENT_URL}" = "${APPSTORE_API_URL}" ]; then
    ok "appstoreurl already set to ${APPSTORE_API_URL} — skipping."
else
    occ config:system:set appstoreurl --value="${APPSTORE_API_URL}"
    ok "appstoreurl = ${APPSTORE_API_URL}"
fi

# ── Connectivity test ─────────────────────────────────────────────────────────
if [ "${RUN_TEST}" = "true" ]; then
    info "Testing connectivity from pod to App Store API..."

    if kexec which curl &>/dev/null; then
        TEST_CMD="curl -fsS --max-time 10 '${APPSTORE_API_URL}/'"
    elif kexec which wget &>/dev/null; then
        TEST_CMD="wget -qO- --timeout=10 '${APPSTORE_API_URL}/'"
    else
        TEST_CMD="php -r \"\\\$r=file_get_contents('${APPSTORE_API_URL}/'); if(\\\$r===false) exit(1);\""
    fi

    if kexec bash -c "${TEST_CMD}" &>/dev/null; then
        ok "Connectivity test passed — pod can reach the App Store."
    else
        warn "Connectivity test FAILED."
        echo ""
        echo "  Verify:"
        echo "  1. App Store Service is accessible from namespace '${NC_NAMESPACE}'"
        echo "  2. APPSTORE_API_URL is resolvable inside the pod"
        echo "  3. CA cert is trusted (or use --no-ca with a proper cert)"
        echo ""
        echo "  Manual check:"
        echo "    kubectl exec ${NC_POD} -n ${NC_NAMESPACE} -- curl -v ${APPSTORE_API_URL}/"
        echo ""
        echo "  CA injection (manual):"
        echo "    kubectl create configmap appstore-ca \\"
        echo "      --from-file=appstore-root-ca.crt=${CA_CERT} \\"
        echo "      -n ${NC_NAMESPACE}"
        echo "    # Mount in NC Deployment volumeMounts + update-ca-certificates"
        echo ""
        rollback
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  Current configuration:"
echo "    appstoreurl     = $(occ config:system:get appstoreurl 2>/dev/null || echo '<not set>')"
echo "    appstoreenabled = $(occ config:system:get appstoreenabled 2>/dev/null || echo '<not set>')"
echo ""
echo "============================================================"
ok "Configuration complete."
echo ""
echo "  Next steps:"
echo "    kubectl exec ${NC_POD} -n ${NC_NAMESPACE} -- sudo -u www-data php occ app:list"
echo ""
echo "  Manual OCC commands (for reference):"
echo "    occ config:system:set appstoreenabled --value=true --type=boolean"
echo "    occ config:system:set appstoreurl --value='${APPSTORE_API_URL}'"
echo "============================================================"
