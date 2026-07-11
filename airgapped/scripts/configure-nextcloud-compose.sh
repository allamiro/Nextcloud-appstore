#!/usr/bin/env bash
# =============================================================================
# Configure an existing Docker Compose Nextcloud to use the local App Store
# =============================================================================
# Behaviour:
#   - Backs up current appstoreurl / appstoreenabled before changing them
#   - Skips occ calls where the value is already correct (idempotent)
#   - Installs the self-signed CA cert if k8s/certs/root-ca.crt exists
#   - Tests connectivity from inside the Nextcloud container
#   - Rolls back to the backup values on any failure
#
# Usage:
#   ./airgapped/scripts/configure-nextcloud-compose.sh [--no-ca] [--no-test]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

APPSTORE_API_URL="${APPSTORE_API_URL:-https://appstore.local/api/v1}"
NC_CONTAINER="${NEXTCLOUD_CONTAINER_NAME:-nextcloud}"
CA_CERT="${PROJECT_DIR}/k8s/certs/root-ca.crt"
BACKUP_FILE="${PROJECT_DIR}/exports/.nc-config-backup-compose.env"

INSTALL_CA=true
RUN_TEST=true
for arg in "$@"; do
    case "${arg}" in
        --no-ca)    INSTALL_CA=false ;;
        --no-test)  RUN_TEST=false ;;
    esac
done

info()    { echo "[INFO]  $*"; }
ok()      { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
error()   { echo "[ERROR] $*" >&2; }
occ()     { docker exec -u www-data "${NC_CONTAINER}" php occ "$@"; }

echo "============================================================"
echo "Configure Nextcloud → Local App Store (Compose)"
echo "  Container       : ${NC_CONTAINER}"
echo "  App Store URL   : ${APPSTORE_API_URL}"
echo "============================================================"
echo ""

# ── Verify container is running ───────────────────────────────────────────────
if ! docker inspect "${NC_CONTAINER}" --format='{{.State.Status}}' 2>/dev/null | grep -q running; then
    error "Container '${NC_CONTAINER}' is not running."
    echo "Set NEXTCLOUD_CONTAINER_NAME in .env to the correct container name."
    echo "Running containers:"
    docker ps --format '  {{.Names}}' | grep -iv "${NC_CONTAINER}" || true
    docker ps --format '  {{.Names}}'
    exit 1
fi

# ── Backup current config ─────────────────────────────────────────────────────
mkdir -p "$(dirname "${BACKUP_FILE}")"
PREV_URL="$(occ config:system:get appstoreurl 2>/dev/null || echo "")"
PREV_ENABLED="$(occ config:system:get appstoreenabled 2>/dev/null || echo "")"
cat > "${BACKUP_FILE}" <<EOF
# NC config backup — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
PREV_APPSTOREURL=${PREV_URL}
PREV_APPSTOREENABLED=${PREV_ENABLED}
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

# ── Install CA certificate ────────────────────────────────────────────────────
if [ "${INSTALL_CA}" = "true" ] && [ -f "${CA_CERT}" ]; then
    info "Installing self-signed CA certificate..."
    docker cp "${CA_CERT}" "${NC_CONTAINER}:/usr/local/share/ca-certificates/appstore-root-ca.crt"
    docker exec "${NC_CONTAINER}" update-ca-certificates 2>/dev/null || \
        warn "update-ca-certificates failed — CA may not be trusted. Check container OS."
    ok "CA certificate installed."
elif [ "${INSTALL_CA}" = "true" ] && [ ! -f "${CA_CERT}" ]; then
    warn "CA cert not found at ${CA_CERT} — skipping TLS trust installation."
    warn "If using a self-signed cert, manually install it before testing connectivity."
fi

# ── Apply configuration ───────────────────────────────────────────────────────
info "Applying configuration..."

# appstoreenabled
CURRENT_ENABLED="$(occ config:system:get appstoreenabled 2>/dev/null || echo "")"
if [ "${CURRENT_ENABLED}" = "true" ]; then
    ok "appstoreenabled already true — skipping."
else
    occ config:system:set appstoreenabled --value=true --type=boolean
    ok "appstoreenabled = true"
fi

# appstoreurl
CURRENT_URL="$(occ config:system:get appstoreurl 2>/dev/null || echo "")"
if [ "${CURRENT_URL}" = "${APPSTORE_API_URL}" ]; then
    ok "appstoreurl already set to ${APPSTORE_API_URL} — skipping."
else
    occ config:system:set appstoreurl --value="${APPSTORE_API_URL}"
    ok "appstoreurl = ${APPSTORE_API_URL}"
fi

# ── Connectivity test from inside the container ───────────────────────────────
if [ "${RUN_TEST}" = "true" ]; then
    info "Testing connectivity from Nextcloud container to App Store API..."

    # curl may not be available in all NC images; fall back to wget or PHP
    if docker exec "${NC_CONTAINER}" which curl &>/dev/null; then
        TEST_CMD="curl -fsS --max-time 10 --connect-timeout 5 '${APPSTORE_API_URL}/'"
    elif docker exec "${NC_CONTAINER}" which wget &>/dev/null; then
        TEST_CMD="wget -qO- --timeout=10 '${APPSTORE_API_URL}/'"
    else
        TEST_CMD="php -r \"\\\$r=file_get_contents('${APPSTORE_API_URL}/'); if(\\\$r===false) exit(1);\""
    fi

    if docker exec "${NC_CONTAINER}" bash -c "${TEST_CMD}" &>/dev/null; then
        ok "Connectivity test passed — Nextcloud can reach the App Store."
    else
        warn "Connectivity test FAILED."
        echo ""
        echo "  Verify:"
        echo "  1. App Store is running and reachable on your network"
        echo "  2. APPSTORE_API_URL is correct in .env (currently: ${APPSTORE_API_URL})"
        echo "  3. The CA cert is trusted inside the Nextcloud container"
        echo "  4. DNS resolves '$(echo "${APPSTORE_API_URL}" | sed 's|https\?://||;s|/.*||')' inside the NC container"
        echo ""
        echo "  Manual check:"
        echo "    docker exec ${NC_CONTAINER} curl -v ${APPSTORE_API_URL}/"
        echo ""
        rollback
    fi
fi

# ── Verification printout ─────────────────────────────────────────────────────
echo ""
echo "  Current Nextcloud App Store configuration:"
echo "    appstoreurl     = $(occ config:system:get appstoreurl 2>/dev/null || echo '<not set>')"
echo "    appstoreenabled = $(occ config:system:get appstoreenabled 2>/dev/null || echo '<not set>')"
echo ""
echo "============================================================"
ok "Configuration complete."
echo ""
echo "  Next steps:"
echo "    1. Open Nextcloud as admin → Apps"
echo "    2. Confirm apps are listed from the local App Store"
echo "    3. Run: ./scripts/appstorectl.sh airgap test compose"
echo ""
echo "  Manual OCC commands (for reference):"
echo "    occ config:system:set appstoreenabled --value=true --type=boolean"
echo "    occ config:system:set appstoreurl --value='${APPSTORE_API_URL}'"
echo "============================================================"
