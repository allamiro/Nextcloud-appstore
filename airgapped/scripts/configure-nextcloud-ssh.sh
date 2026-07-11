#!/usr/bin/env bash
# =============================================================================
# Configure an SSH / bare-metal Nextcloud to use the local App Store
# =============================================================================
# Behaviour:
#   - Backs up current appstoreurl / appstoreenabled before changing them
#   - Skips occ calls where the value is already correct (idempotent)
#   - Copies and installs CA cert on remote host if k8s/certs/root-ca.crt exists
#   - Tests connectivity from the remote host to the App Store API
#   - Rolls back to the backup values on any failure
#
# Usage:
#   ./airgapped/scripts/configure-nextcloud-ssh.sh [--no-ca] [--no-test]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

APPSTORE_API_URL="${APPSTORE_API_URL:-https://appstore.local/api/v1}"
NC_SSH_HOST="${NEXTCLOUD_SSH_HOST:-}"
NC_SSH_USER="${NEXTCLOUD_SSH_USER:-}"
NC_PATH="${NEXTCLOUD_PATH:-/var/www/html}"
CA_CERT="${PROJECT_DIR}/k8s/certs/root-ca.crt"
BACKUP_FILE="${PROJECT_DIR}/exports/.nc-config-backup-ssh.env"

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

[ -n "${NC_SSH_HOST}" ] || { error "NEXTCLOUD_SSH_HOST is not set. Set it in .env"; exit 1; }
[ -n "${NC_SSH_USER}" ] || { error "NEXTCLOUD_SSH_USER is not set. Set it in .env"; exit 1; }

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

remote() { ssh "${SSH_OPTS[@]}" "${NC_SSH_USER}@${NC_SSH_HOST}" "$@"; }
# shellcheck disable=SC2029  # NC_PATH and $* expand client-side intentionally to build the remote command
occ()    { remote "cd '${NC_PATH}' && sudo -u www-data php occ $*"; }

echo "============================================================"
echo "Configure SSH Nextcloud → Local App Store"
echo "  SSH Host   : ${NC_SSH_USER}@${NC_SSH_HOST}"
echo "  NC Path    : ${NC_PATH}"
echo "  API URL    : ${APPSTORE_API_URL}"
echo "============================================================"
echo ""

# ── Verify SSH connectivity ───────────────────────────────────────────────────
info "Testing SSH connectivity..."
if ! remote "echo connected" &>/dev/null; then
    error "Cannot connect to ${NC_SSH_USER}@${NC_SSH_HOST} via SSH."
    echo "Ensure SSH key authentication is configured."
    exit 1
fi
ok "SSH connectivity OK."

# ── Backup current config ─────────────────────────────────────────────────────
mkdir -p "$(dirname "${BACKUP_FILE}")"
PREV_URL="$(occ "config:system:get appstoreurl" 2>/dev/null || echo "")"
PREV_ENABLED="$(occ "config:system:get appstoreenabled" 2>/dev/null || echo "")"
cat > "${BACKUP_FILE}" <<EOF
# NC SSH config backup — $(date -u +"%Y-%m-%dT%H:%M:%SZ")
PREV_APPSTOREURL=${PREV_URL}
PREV_APPSTOREENABLED=${PREV_ENABLED}
NC_SSH_HOST=${NC_SSH_HOST}
NC_SSH_USER=${NC_SSH_USER}
NC_PATH=${NC_PATH}
EOF
info "Config backed up to ${BACKUP_FILE}"

# ── Rollback helper ───────────────────────────────────────────────────────────
rollback() {
    warn "Rolling back to previous configuration..."
    if [ -n "${PREV_URL}" ]; then
        occ "config:system:set appstoreurl --value='${PREV_URL}'" &>/dev/null || true
    else
        occ "config:system:delete appstoreurl" &>/dev/null || true
    fi
    if [ -n "${PREV_ENABLED}" ]; then
        occ "config:system:set appstoreenabled --value='${PREV_ENABLED}' --type=boolean" &>/dev/null || true
    fi
    error "Configuration rolled back. Fix the issue and re-run."
    exit 1
}

# ── Install CA certificate on remote host ─────────────────────────────────────
if [ "${INSTALL_CA}" = "true" ] && [ -f "${CA_CERT}" ]; then
    info "Copying CA certificate to remote host..."
    scp "${SSH_OPTS[@]}" "${CA_CERT}" \
        "${NC_SSH_USER}@${NC_SSH_HOST}:/tmp/appstore-root-ca.crt" &>/dev/null
    remote "sudo cp /tmp/appstore-root-ca.crt /usr/local/share/ca-certificates/appstore-root-ca.crt \
        && sudo update-ca-certificates 2>&1 | tail -3"
    ok "CA certificate installed on remote host."
elif [ "${INSTALL_CA}" = "true" ] && [ ! -f "${CA_CERT}" ]; then
    warn "CA cert not found at ${CA_CERT} — skipping TLS trust installation."
fi

# ── Apply configuration ───────────────────────────────────────────────────────
info "Applying configuration..."

CURRENT_ENABLED="$(occ "config:system:get appstoreenabled" 2>/dev/null || echo "")"
if [ "${CURRENT_ENABLED}" = "true" ]; then
    ok "appstoreenabled already true — skipping."
else
    occ "config:system:set appstoreenabled --value=true --type=boolean"
    ok "appstoreenabled = true"
fi

CURRENT_URL="$(occ "config:system:get appstoreurl" 2>/dev/null || echo "")"
if [ "${CURRENT_URL}" = "${APPSTORE_API_URL}" ]; then
    ok "appstoreurl already set to ${APPSTORE_API_URL} — skipping."
else
    occ "config:system:set appstoreurl --value='${APPSTORE_API_URL}'"
    ok "appstoreurl = ${APPSTORE_API_URL}"
fi

# ── Connectivity test from the remote host ────────────────────────────────────
if [ "${RUN_TEST}" = "true" ]; then
    info "Testing connectivity from remote host to App Store API..."

    if remote "which curl" &>/dev/null; then
        REMOTE_TEST="curl -fsS --max-time 10 '${APPSTORE_API_URL}/'"
    elif remote "which wget" &>/dev/null; then
        REMOTE_TEST="wget -qO- --timeout=10 '${APPSTORE_API_URL}/'"
    else
        REMOTE_TEST="php -r \"\\\$r=file_get_contents('${APPSTORE_API_URL}/'); if(\\\$r===false) exit(1);\""
    fi

    if remote "${REMOTE_TEST}" &>/dev/null; then
        ok "Connectivity test passed — remote host can reach the App Store."
    else
        warn "Connectivity test FAILED."
        echo ""
        echo "  Verify:"
        echo "  1. App Store is reachable from ${NC_SSH_HOST}"
        echo "  2. APPSTORE_API_URL resolves correctly on the remote host"
        echo "  3. CA cert is installed and update-ca-certificates was run"
        echo "  4. Firewall allows outbound HTTPS from ${NC_SSH_HOST}"
        echo ""
        echo "  Manual check:"
        echo "    ssh ${NC_SSH_USER}@${NC_SSH_HOST} curl -v ${APPSTORE_API_URL}/"
        echo ""
        rollback
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "  Current configuration on ${NC_SSH_HOST}:"
echo "    appstoreurl     = $(occ "config:system:get appstoreurl" 2>/dev/null || echo '<not set>')"
echo "    appstoreenabled = $(occ "config:system:get appstoreenabled" 2>/dev/null || echo '<not set>')"
echo ""
echo "============================================================"
ok "Configuration complete."
echo ""
echo "  Validate on remote host:"
echo "    ssh ${NC_SSH_USER}@${NC_SSH_HOST} \\"
echo "      \"cd ${NC_PATH} && sudo -u www-data php occ app:list\""
echo ""
echo "  Manual OCC commands (for reference):"
echo "    cd ${NC_PATH}"
echo "    sudo -u www-data php occ config:system:set appstoreenabled --value=true --type=boolean"
echo "    sudo -u www-data php occ config:system:set appstoreurl --value='${APPSTORE_API_URL}'"
echo "============================================================"
