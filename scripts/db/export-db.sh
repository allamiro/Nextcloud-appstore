#!/bin/bash
# =============================================================================
# PostgreSQL Database Export Script
# =============================================================================
# Run this on staging to export the database for transfer to disconnected env
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_DIR="${SCRIPT_DIR}/../../exports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Database connection settings
DB_HOST="${DATABASE_HOST:-localhost}"
DB_PORT="${DATABASE_PORT:-5432}"
DB_NAME="${DATABASE_NAME:-nextcloudappstore}"
DB_USER="${DATABASE_USER:-nextcloudappstore}"

# Export filename
EXPORT_FILE="${EXPORT_DIR}/appstore_db_${TIMESTAMP}.sql"
EXPORT_FILE_GZ="${EXPORT_FILE}.gz"

echo "=============================================="
echo "PostgreSQL Database Export"
echo "=============================================="
echo "Host: ${DB_HOST}:${DB_PORT}"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Export to: ${EXPORT_FILE_GZ}"
echo "=============================================="

# Create export directory
mkdir -p "${EXPORT_DIR}"

# Export database
echo "Exporting database..."
PGPASSWORD="${DATABASE_PASSWORD}" pg_dump \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
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
sha256sum "${EXPORT_FILE_GZ}" > "${EXPORT_FILE_GZ}.sha256"

echo "=============================================="
echo "Export completed successfully!"
echo "Files created:"
echo "  - ${EXPORT_FILE_GZ}"
echo "  - ${EXPORT_FILE_GZ}.sha256"
echo ""
echo "Transfer these files to your disconnected environment."
echo "=============================================="
