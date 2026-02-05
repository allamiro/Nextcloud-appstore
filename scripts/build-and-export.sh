#!/bin/bash
# =============================================================================
# Build and Export Script for Air-Gapped Deployment
# =============================================================================
# Run this on your internet-connected staging system
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
EXPORT_DIR="${PROJECT_DIR}/exports"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Configuration
IMAGE_NAME="nextcloudappstore"
IMAGE_TAG="${IMAGE_TAG:-latest}"
APPSTORE_VERSION="${APPSTORE_VERSION:-master}"

echo "=============================================="
echo "Nextcloud App Store - Build and Export"
echo "=============================================="
echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo "App Store Version: ${APPSTORE_VERSION}"
echo "Export Directory: ${EXPORT_DIR}"
echo "=============================================="

cd "${PROJECT_DIR}"

# Create export directory
mkdir -p "${EXPORT_DIR}"

# Step 1: Build the Docker image
echo ""
echo "[1/5] Building Docker image..."
docker build \
    --build-arg APPSTORE_VERSION="${APPSTORE_VERSION}" \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    -f Dockerfile \
    .

# Step 2: Save the image to a tar file
echo ""
echo "[2/5] Exporting Docker image..."
IMAGE_FILE="${EXPORT_DIR}/${IMAGE_NAME}_${IMAGE_TAG}_${TIMESTAMP}.tar"
docker save -o "${IMAGE_FILE}" "${IMAGE_NAME}:${IMAGE_TAG}"

# Step 3: Compress the image
echo ""
echo "[3/5] Compressing image..."
gzip -f "${IMAGE_FILE}"
IMAGE_FILE_GZ="${IMAGE_FILE}.gz"

# Step 4: Create checksums
echo ""
echo "[4/5] Creating checksums..."
sha256sum "${IMAGE_FILE_GZ}" > "${IMAGE_FILE_GZ}.sha256"

# Step 5: Export additional required images
echo ""
echo "[5/5] Exporting additional images..."

# PostgreSQL image
echo "  - Pulling and exporting PostgreSQL..."
docker pull postgres:15-alpine
POSTGRES_FILE="${EXPORT_DIR}/postgres_15-alpine_${TIMESTAMP}.tar"
docker save -o "${POSTGRES_FILE}" postgres:15-alpine
gzip -f "${POSTGRES_FILE}"
sha256sum "${POSTGRES_FILE}.gz" > "${POSTGRES_FILE}.gz.sha256"

# Nginx image
echo "  - Pulling and exporting Nginx..."
docker pull nginx:alpine
NGINX_FILE="${EXPORT_DIR}/nginx_alpine_${TIMESTAMP}.tar"
docker save -o "${NGINX_FILE}" nginx:alpine
gzip -f "${NGINX_FILE}"
sha256sum "${NGINX_FILE}.gz" > "${NGINX_FILE}.gz.sha256"

# Copy configuration files
echo ""
echo "Copying configuration files..."
cp -r "${PROJECT_DIR}/config" "${EXPORT_DIR}/"
cp -r "${PROJECT_DIR}/nginx" "${EXPORT_DIR}/"
cp -r "${PROJECT_DIR}/k8s" "${EXPORT_DIR}/"
cp "${PROJECT_DIR}/docker-compose.yml" "${EXPORT_DIR}/"

echo ""
echo "=============================================="
echo "Build and Export Complete!"
echo "=============================================="
echo ""
echo "Files created in ${EXPORT_DIR}:"
ls -lh "${EXPORT_DIR}"/*.gz 2>/dev/null || true
echo ""
echo "Next steps:"
echo "1. Run the staging environment to populate the database"
echo "2. Export the database using: ./scripts/db/export-db.sh"
echo "3. Transfer the exports/ directory to your disconnected server"
echo "4. On the disconnected server, run: ./scripts/import-and-deploy.sh"
echo "=============================================="
