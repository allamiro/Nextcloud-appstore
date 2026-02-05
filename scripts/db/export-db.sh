#!/bin/bash
# =============================================================================
# PostgreSQL Database Export Script
# =============================================================================
# Run this on staging to export the database for transfer to disconnected env
# Uses docker-compose to run pg_dump inside the postgres container
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/../.."
EXPORT_DIR="${PROJECT_DIR}/exports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Database settings
DB_NAME="${DATABASE_NAME:-nextcloudappstore}"
DB_USER="${DATABASE_USER:-nextcloudappstore}"

# Export filename
EXPORT_FILE="${EXPORT_DIR}/appstore_db_${TIMESTAMP}.sql"
EXPORT_FILE_GZ="${EXPORT_FILE}.gz"

echo "=============================================="
echo "PostgreSQL Database Export"
echo "=============================================="
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Export to: ${EXPORT_FILE_GZ}"
echo "=============================================="

# Create export directory
mkdir -p "${EXPORT_DIR}"

# Check if containers are running
cd "${PROJECT_DIR}"
if ! docker-compose ps postgres | grep -q "Up"; then
    echo "ERROR: PostgreSQL container is not running!"
    echo "Start it with: docker-compose up -d postgres"
    exit 1
fi

# Export database using docker-compose exec
echo "Exporting database from container..."
docker-compose exec -T postgres pg_dump \
    -U "${DB_USER}" \
    -d "${DB_NAME}" \
    --no-owner \
    --no-acl \
    --clean \
    --if-exists \
    --format=plain \
    > "${EXPORT_FILE}"

# Compress
echo "Compressing export..."
gzip -f "${EXPORT_FILE}"

# Create checksum
echo "Creating checksum..."
if command -v sha256sum &> /dev/null; then
    sha256sum "${EXPORT_FILE_GZ}" > "${EXPORT_FILE_GZ}.sha256"
elif command -v shasum &> /dev/null; then
    shasum -a 256 "${EXPORT_FILE_GZ}" > "${EXPORT_FILE_GZ}.sha256"
else
    echo "Warning: No sha256sum or shasum found, skipping checksum"
fi

# Show file size
FILE_SIZE=$(ls -lh "${EXPORT_FILE_GZ}" | awk '{print $5}')

echo "=============================================="
echo "Export completed successfully!"
echo "=============================================="
echo "File: ${EXPORT_FILE_GZ}"
echo "Size: ${FILE_SIZE}"
echo ""
echo "Transfer this file to your disconnected environment."
echo "=============================================="
