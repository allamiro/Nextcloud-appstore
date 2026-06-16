#!/usr/bin/env bash
# =============================================================================
# Configure an existing Docker Compose Nextcloud to use the local App Store
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/../../"

# Load .env from project root if present
if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

APPSTORE_API_URL="${APPSTORE_API_URL:-https://appstore.local/api/v1}"
NC_PROJECT_DIR="${NEXTCLOUD_COMPOSE_PROJECT_DIR:-/opt/nextcloud}"
NC_COMPOSE_FILE="${NEXTCLOUD_COMPOSE_FILE:-docker-compose.yml}"
NC_CONTAINER="${NEXTCLOUD_CONTAINER_NAME:-nextcloud}"

echo "=============================================="
echo "Configure Nextcloud → Local App Store"
echo "=============================================="
echo "Nextcloud container : ${NC_CONTAINER}"
echo "Compose project dir : ${NC_PROJECT_DIR}"
echo "App Store API URL   : ${APPSTORE_API_URL}"
echo ""

# Verify the Nextcloud container is running
if ! docker inspect "${NC_CONTAINER}" --format='{{.State.Status}}' 2>/dev/null | grep -q running; then
    echo "ERROR: Container '${NC_CONTAINER}' is not running."
    echo "Set NEXTCLOUD_CONTAINER_NAME to the correct container name."
    echo "Running containers:"
    docker ps --format '  {{.Names}}' | grep -i next || echo "  (none matching 'next')"
    exit 1
fi

echo "Enabling App Store and setting URL..."
docker exec -u www-data "${NC_CONTAINER}" \
    php occ config:system:set appstoreenabled --value=true --type=boolean

docker exec -u www-data "${NC_CONTAINER}" \
    php occ config:system:set appstoreurl --value="${APPSTORE_API_URL}"

echo ""
echo "Verifying configuration..."
CONFIGURED_URL="$(docker exec -u www-data "${NC_CONTAINER}" \
    php occ config:system:get appstoreurl)"
echo "  appstoreurl = ${CONFIGURED_URL}"

ENABLED="$(docker exec -u www-data "${NC_CONTAINER}" \
    php occ config:system:get appstoreenabled)"
echo "  appstoreenabled = ${ENABLED}"

echo ""
# TLS trust guidance
CA_CERT="${PROJECT_DIR}/k8s/certs/root-ca.crt"
if [ -f "${CA_CERT}" ]; then
    echo "--- TLS Trust (self-signed CA detected) ---"
    echo "To trust the App Store CA inside Nextcloud, copy the CA cert into the container:"
    echo ""
    echo "  docker cp ${CA_CERT} ${NC_CONTAINER}:/usr/local/share/ca-certificates/appstore-root-ca.crt"
    echo "  docker exec ${NC_CONTAINER} update-ca-certificates"
    echo "  docker restart ${NC_CONTAINER}"
    echo ""
fi

echo "=============================================="
echo "Nextcloud configured successfully."
echo "=============================================="
echo ""
echo "Validate inside Nextcloud:"
echo "  docker exec -u www-data ${NC_CONTAINER} php occ config:system:get appstoreurl"
echo "  docker exec -u www-data ${NC_CONTAINER} php occ app:list"
