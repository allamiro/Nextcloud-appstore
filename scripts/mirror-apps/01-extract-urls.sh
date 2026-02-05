#!/bin/bash
# =============================================================================
# Extract all app download URLs from the database
# =============================================================================
# Run this while connected to the internet (staging environment)
# Output: urls.txt with all GitHub download URLs
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../../exports/app-archives"
URLS_FILE="${OUTPUT_DIR}/urls.txt"

echo "=============================================="
echo "Extracting App Download URLs"
echo "=============================================="

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Check if running in docker-compose or k8s
if docker-compose ps postgres 2>/dev/null | grep -q "Up"; then
    echo "Using Docker Compose..."
    docker-compose exec -T postgres psql -U nextcloudappstore -d nextcloudappstore -t -A -c \
        "SELECT DISTINCT download FROM core_apprelease WHERE download != '' AND download IS NOT NULL ORDER BY download;" \
        > "${URLS_FILE}"
elif kubectl get pods -n nextcloud-appstore -l app=postgres 2>/dev/null | grep -q "Running"; then
    echo "Using Kubernetes..."
    PG_POD=$(kubectl get pod -l app=postgres -n nextcloud-appstore -o jsonpath='{.items[0].metadata.name}')
    kubectl exec -i "${PG_POD}" -n nextcloud-appstore -- \
        psql -U nextcloudappstore -d nextcloudappstore -t -A -c \
        "SELECT DISTINCT download FROM core_apprelease WHERE download != '' AND download IS NOT NULL ORDER BY download;" \
        > "${URLS_FILE}"
else
    echo "ERROR: No database connection available!"
    echo "Start docker-compose or ensure K8s postgres is running."
    exit 1
fi

# Count URLs
TOTAL_URLS=$(wc -l < "${URLS_FILE}" | tr -d ' ')
GITHUB_URLS=$(grep -c "github.com" "${URLS_FILE}" || echo "0")

echo ""
echo "=============================================="
echo "Extraction Complete!"
echo "=============================================="
echo "Total URLs: ${TOTAL_URLS}"
echo "GitHub URLs: ${GITHUB_URLS}"
echo "Output file: ${URLS_FILE}"
echo ""
echo "Next step: Run 02-download-apps.sh to download all archives"
echo "=============================================="
