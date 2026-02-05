#!/bin/bash
# =============================================================================
# Update database URLs to point to local file server
# =============================================================================
# Run this after downloading all app archives
# Updates all GitHub URLs to point to your local file server
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration - CHANGE THIS to your file server URL
FILE_SERVER_URL="${FILE_SERVER_URL:-https://files.local/apps}"

echo "=============================================="
echo "Update Database URLs for Local Mirror"
echo "=============================================="
echo "New base URL: ${FILE_SERVER_URL}"
echo "=============================================="
echo ""

# SQL to update URLs
# This replaces the full GitHub path with just the filename on your server
SQL_UPDATE="
UPDATE core_apprelease 
SET download = '${FILE_SERVER_URL}/' || 
    regexp_replace(download, '^.*/([^/]+)\$', '\\1')
WHERE download LIKE '%github.com%' 
  AND download != '';
"

SQL_COUNT="
SELECT COUNT(*) FROM core_apprelease 
WHERE download LIKE '%github.com%' AND download != '';
"

SQL_VERIFY="
SELECT download FROM core_apprelease 
WHERE download != '' LIMIT 5;
"

# Check if running in docker-compose or k8s
if docker-compose ps postgres 2>/dev/null | grep -q "Up"; then
    echo "Using Docker Compose..."
    
    # Count before
    BEFORE=$(docker-compose exec -T postgres psql -U nextcloudappstore -d nextcloudappstore -t -A -c "${SQL_COUNT}")
    echo "URLs to update: ${BEFORE}"
    
    read -p "Proceed with update? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
    
    # Update
    docker-compose exec -T postgres psql -U nextcloudappstore -d nextcloudappstore -c "${SQL_UPDATE}"
    
    # Verify
    echo ""
    echo "Sample URLs after update:"
    docker-compose exec -T postgres psql -U nextcloudappstore -d nextcloudappstore -c "${SQL_VERIFY}"
    
elif kubectl get pods -n nextcloud-appstore -l app=postgres 2>/dev/null | grep -q "Running"; then
    echo "Using Kubernetes..."
    PG_POD=$(kubectl get pod -l app=postgres -n nextcloud-appstore -o jsonpath='{.items[0].metadata.name}')
    
    # Count before
    BEFORE=$(kubectl exec -i "${PG_POD}" -n nextcloud-appstore -- psql -U nextcloudappstore -d nextcloudappstore -t -A -c "${SQL_COUNT}")
    echo "URLs to update: ${BEFORE}"
    
    read -p "Proceed with update? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
    
    # Update
    kubectl exec -i "${PG_POD}" -n nextcloud-appstore -- psql -U nextcloudappstore -d nextcloudappstore -c "${SQL_UPDATE}"
    
    # Verify
    echo ""
    echo "Sample URLs after update:"
    kubectl exec -i "${PG_POD}" -n nextcloud-appstore -- psql -U nextcloudappstore -d nextcloudappstore -c "${SQL_VERIFY}"
else
    echo "ERROR: No database connection available!"
    exit 1
fi

echo ""
echo "=============================================="
echo "Update Complete!"
echo "=============================================="
echo "All GitHub URLs now point to: ${FILE_SERVER_URL}/"
echo ""
echo "Next steps:"
echo "1. Export the updated database: sh scripts/db/export-db.sh"
echo "2. Set up a file server at: ${FILE_SERVER_URL}"
echo "3. Copy files from exports/app-archives/files/ to file server"
echo "=============================================="
