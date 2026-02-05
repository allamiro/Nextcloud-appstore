#!/bin/bash
# =============================================================================
# PostgreSQL Database Import Script
# =============================================================================
# Run this on the disconnected environment to import the database
# Supports both docker-compose and Kubernetes environments
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/../.."

# Database settings
DB_NAME="${DATABASE_NAME:-nextcloudappstore}"
DB_USER="${DATABASE_USER:-nextcloudappstore}"
K8S_NAMESPACE="${K8S_NAMESPACE:-nextcloud-appstore}"

# Import file (pass as argument)
IMPORT_FILE="${1}"
MODE="${2:-docker}"  # docker or k8s

if [ -z "${IMPORT_FILE}" ]; then
    echo "Usage: $0 <path-to-sql-dump.sql.gz> [docker|k8s]"
    echo ""
    echo "Examples:"
    echo "  $0 ./exports/appstore_db_20240101_120000.sql.gz docker"
    echo "  $0 ./exports/appstore_db_20240101_120000.sql.gz k8s"
    exit 1
fi

if [ ! -f "${IMPORT_FILE}" ]; then
    echo "Error: Import file not found: ${IMPORT_FILE}"
    exit 1
fi

echo "=============================================="
echo "PostgreSQL Database Import"
echo "=============================================="
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Mode: ${MODE}"
echo "Import from: ${IMPORT_FILE}"
echo "=============================================="

# Verify checksum if available
CHECKSUM_FILE="${IMPORT_FILE}.sha256"
if [ -f "${CHECKSUM_FILE}" ]; then
    echo "Verifying checksum..."
    if command -v sha256sum &> /dev/null; then
        if sha256sum -c "${CHECKSUM_FILE}"; then
            echo "Checksum verified!"
        else
            echo "ERROR: Checksum verification failed!"
            exit 1
        fi
    elif command -v shasum &> /dev/null; then
        if shasum -a 256 -c "${CHECKSUM_FILE}"; then
            echo "Checksum verified!"
        else
            echo "ERROR: Checksum verification failed!"
            exit 1
        fi
    else
        echo "Warning: No sha256sum or shasum found, skipping checksum verification"
    fi
fi

# Import based on mode
echo "Importing database (this may take a while)..."

if [ "${MODE}" = "k8s" ]; then
    # Kubernetes mode
    PG_POD=$(kubectl get pod -l app=postgres -n "${K8S_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
    if [ -z "${PG_POD}" ]; then
        echo "ERROR: PostgreSQL pod not found in namespace ${K8S_NAMESPACE}"
        exit 1
    fi
    echo "Using Kubernetes pod: ${PG_POD}"
    gunzip -c "${IMPORT_FILE}" | kubectl exec -i "${PG_POD}" -n "${K8S_NAMESPACE}" -- \
        psql -U "${DB_USER}" -d "${DB_NAME}" --quiet
else
    # Docker-compose mode
    cd "${PROJECT_DIR}"
    if ! docker-compose ps postgres | grep -q "Up"; then
        echo "ERROR: PostgreSQL container is not running!"
        echo "Start it with: docker-compose up -d postgres"
        exit 1
    fi
    gunzip -c "${IMPORT_FILE}" | docker-compose exec -T postgres \
        psql -U "${DB_USER}" -d "${DB_NAME}" --quiet
fi

echo "=============================================="
echo "Import completed successfully!"
echo "=============================================="
