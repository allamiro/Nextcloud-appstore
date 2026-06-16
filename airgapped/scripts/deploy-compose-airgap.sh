#!/usr/bin/env bash
# =============================================================================
# Deploy App Store air-gapped stack with Docker Compose
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/../docker-compose"
PROJECT_DIR="${SCRIPT_DIR}/../../"

# Load .env from project root if present
if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

APPSTORE_DOMAIN="${APPSTORE_DOMAIN:-appstore.local}"
FILESERVER_DOMAIN="${FILESERVER_DOMAIN:-files.local}"

echo "=============================================="
echo "Deploy Air-Gapped App Store (Docker Compose)"
echo "=============================================="
echo "Compose dir: ${COMPOSE_DIR}"
echo ""

# Ensure images are loaded
if ! docker image inspect nextcloudappstore:latest &>/dev/null; then
    echo "ERROR: nextcloudappstore:latest image not found."
    echo "Run first: ./scripts/appstorectl.sh airgap load-images"
    exit 1
fi

# Ensure TLS certs exist
if [ ! -f "${PROJECT_DIR}/nginx/ssl/server.crt" ]; then
    echo "ERROR: TLS certificates not found at nginx/ssl/"
    echo "Generate them first: bash k8s/generate-certs.sh"
    exit 1
fi

# Symlink the latest DB dump for the db-import service
EXPORTS_DIR="${SCRIPT_DIR}/../exports"
LATEST_DUMP="$(find "${EXPORTS_DIR}" -name 'appstore_db_*.sql.gz' 2>/dev/null | sort -r | head -1 || true)"
if [ -n "${LATEST_DUMP}" ]; then
    echo "Linking latest DB dump: $(basename "${LATEST_DUMP}")"
    ln -sf "$(basename "${LATEST_DUMP}")" "${EXPORTS_DIR}/appstore_db_latest.sql.gz"
else
    echo "WARNING: No DB dump found in ${EXPORTS_DIR} — App Store will start with an empty database."
fi

echo "Starting services..."
docker compose -f "${COMPOSE_DIR}/docker-compose.airgapped.yml" \
    --env-file "${COMPOSE_DIR}/.env.airgapped.example" \
    up -d

echo ""
echo "Waiting for App Store to become healthy..."
RETRIES=20
until docker inspect appstore-app --format='{{.State.Health.Status}}' 2>/dev/null | grep -q healthy || [ "${RETRIES}" -eq 0 ]; do
    echo "  Waiting... (${RETRIES} retries left)"
    sleep 5
    RETRIES=$((RETRIES - 1))
done

echo ""
echo "=============================================="
echo "Air-Gapped Compose Deployment Complete"
echo "=============================================="
echo ""
echo "  App Store HTTPS : https://localhost:30443"
echo "  App Store Admin : https://localhost:30443/admin/"
echo "  File Server     : https://localhost:30444/apps/"
echo ""
echo "Validate:"
echo "  docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml ps"
echo "  curl -k https://localhost:30443/health/"
echo "  curl -k https://localhost:30444/apps/"
echo ""
echo "To add a test Nextcloud:"
echo "  docker compose \\"
echo "    -f airgapped/docker-compose/docker-compose.airgapped.yml \\"
echo "    -f airgapped/docker-compose/docker-compose.nextcloud-test.yml \\"
echo "    up -d"
