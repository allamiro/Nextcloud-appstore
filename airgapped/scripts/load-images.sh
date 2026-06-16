#!/usr/bin/env bash
# =============================================================================
# Load Docker images from airgapped/images/ into the local container runtime
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="${SCRIPT_DIR}/../images"

echo "=============================================="
echo "Loading Air-Gapped Docker Images"
echo "=============================================="
echo "Images directory: ${IMAGES_DIR}"
echo ""

if [ ! -d "${IMAGES_DIR}" ]; then
    echo "ERROR: Images directory not found: ${IMAGES_DIR}"
    echo "Build the package first with: ./scripts/appstorectl.sh package build"
    exit 1
fi

IMAGE_FILES=("${IMAGES_DIR}"/*.tar.gz)
if [ ! -f "${IMAGE_FILES[0]}" ]; then
    echo "ERROR: No .tar.gz image files found in ${IMAGES_DIR}"
    echo "Build the package first with: ./scripts/appstorectl.sh package build"
    exit 1
fi

LOADED=0
FAILED=0

for file in "${IMAGES_DIR}"/*.tar.gz; do
    [ -f "${file}" ] || continue
    name="$(basename "${file}")"

    # Verify checksum if available
    if [ -f "${file}.sha256" ]; then
        echo "Verifying checksum: ${name} ..."
        if command -v sha256sum &>/dev/null; then
            sha256sum -c "${file}.sha256" --quiet || {
                echo "  WARNING: checksum mismatch for ${name}"
            }
        elif command -v shasum &>/dev/null; then
            shasum -a 256 -c "${file}.sha256" || {
                echo "  WARNING: checksum mismatch for ${name}"
            }
        fi
    fi

    echo "Loading: ${name} ..."
    if gunzip -c "${file}" | docker load; then
        echo "  OK"
        LOADED=$((LOADED + 1))
    else
        echo "  FAILED"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "=============================================="
echo "Load complete: ${LOADED} loaded, ${FAILED} failed"
echo "=============================================="

if [ "${FAILED}" -gt 0 ]; then
    exit 1
fi

echo ""
echo "Loaded images:"
docker images | grep -E "(nextcloudappstore|postgres|nginx|nextcloud)" || true
