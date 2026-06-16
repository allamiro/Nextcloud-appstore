#!/usr/bin/env bash
# =============================================================================
# Configure an SSH / bare-metal Nextcloud to use the local App Store
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/../../"

# Load .env from project root if present
if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

APPSTORE_API_URL="${APPSTORE_API_URL:-https://appstore.local/api/v1}"
NC_SSH_HOST="${NEXTCLOUD_SSH_HOST:-}"
NC_SSH_USER="${NEXTCLOUD_SSH_USER:-}"
NC_PATH="${NEXTCLOUD_PATH:-/var/www/html}"

echo "=============================================="
echo "Configure SSH Nextcloud → Local App Store"
echo "=============================================="
echo "SSH Host   : ${NC_SSH_HOST}"
echo "SSH User   : ${NC_SSH_USER}"
echo "NC Path    : ${NC_PATH}"
echo "API URL    : ${APPSTORE_API_URL}"
echo ""

if [ -z "${NC_SSH_HOST}" ]; then
    echo "ERROR: NEXTCLOUD_SSH_HOST is not set."
    echo "Set it in .env or export it before running this script."
    exit 1
fi

if [ -z "${NC_SSH_USER}" ]; then
    echo "ERROR: NEXTCLOUD_SSH_USER is not set."
    exit 1
fi

echo "Testing SSH connectivity..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 \
    "${NC_SSH_USER}@${NC_SSH_HOST}" "echo connected" &>/dev/null; then
    echo "ERROR: Cannot connect to ${NC_SSH_USER}@${NC_SSH_HOST} via SSH."
    echo "Ensure SSH key authentication is set up."
    exit 1
fi
echo "  SSH OK"
echo ""

echo "Enabling App Store and setting URL..."
ssh "${NC_SSH_USER}@${NC_SSH_HOST}" \
    "cd ${NC_PATH} && sudo -u www-data php occ config:system:set appstoreenabled --value=true --type=boolean"

ssh "${NC_SSH_USER}@${NC_SSH_HOST}" \
    "cd ${NC_PATH} && sudo -u www-data php occ config:system:set appstoreurl --value='${APPSTORE_API_URL}'"

echo ""
echo "Verifying configuration..."
ssh "${NC_SSH_USER}@${NC_SSH_HOST}" \
    "cd ${NC_PATH} && sudo -u www-data php occ config:system:get appstoreurl"

echo ""
# TLS trust guidance
CA_CERT="${PROJECT_DIR}/k8s/certs/root-ca.crt"
if [ -f "${CA_CERT}" ]; then
    echo "--- TLS Trust (self-signed CA detected) ---"
    echo "To trust the App Store CA on the remote host:"
    echo ""
    echo "  scp ${CA_CERT} ${NC_SSH_USER}@${NC_SSH_HOST}:/tmp/appstore-root-ca.crt"
    echo "  ssh ${NC_SSH_USER}@${NC_SSH_HOST} \\"
    echo "    'sudo cp /tmp/appstore-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates'"
    echo ""
    echo "Then restart php-fpm or the web server as appropriate."
    echo ""
fi

echo "=============================================="
echo "Nextcloud configured successfully."
echo "=============================================="
echo ""
echo "Validate on the remote host:"
echo "  ssh ${NC_SSH_USER}@${NC_SSH_HOST} \\"
echo "    \"cd ${NC_PATH} && sudo -u www-data php occ config:system:get appstoreurl\""
