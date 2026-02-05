#!/bin/bash
# =============================================================================
# PostgreSQL Database Import Script
# =============================================================================
# Run this on the disconnected environment to import the database
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Database connection settings
DB_HOST="${DATABASE_HOST:-localhost}"
DB_PORT="${DATABASE_PORT:-5432}"
DB_NAME="${DATABASE_NAME:-nextcloudappstore}"
DB_USER="${DATABASE_USER:-nextcloudappstore}"

# Import file (pass as argument)
IMPORT_FILE="${1}"

if [ -z "${IMPORT_FILE}" ]; then
    echo "Usage: $0 <path-to-sql-dump.sql.gz>"
    echo "Example: $0 ./exports/appstore_db_20240101_120000.sql.gz"
    exit 1
fi

if [ ! -f "${IMPORT_FILE}" ]; then
    echo "Error: Import file not found: ${IMPORT_FILE}"
    exit 1
fi

echo "=============================================="
echo "PostgreSQL Database Import"
echo "=============================================="
echo "Host: ${DB_HOST}:${DB_PORT}"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Import from: ${IMPORT_FILE}"
echo "=============================================="

# Verify checksum if available
CHECKSUM_FILE="${IMPORT_FILE}.sha256"
if [ -f "${CHECKSUM_FILE}" ]; then
    echo "Verifying checksum..."
    if sha256sum -c "${CHECKSUM_FILE}"; then
        echo "Checksum verified!"
    else
        echo "ERROR: Checksum verification failed!"
        exit 1
    fi
fi

# Decompress and import
echo "Importing database (this may take a while)..."
gunzip -c "${IMPORT_FILE}" | PGPASSWORD="${DATABASE_PASSWORD}" psql \
    -h "${DB_HOST}" \
    -p "${DB_PORT}" \
    -U "${DB_USER}" \
    -d "${DB_NAME}" \
    --quiet

echo "=============================================="
echo "Import completed successfully!"
echo "=============================================="
