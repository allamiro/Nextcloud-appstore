#!/bin/bash
# =============================================================================
# Download all app archives from GitHub
# =============================================================================
# Run this while connected to the internet (staging environment)
# Reads: urls.txt
# Output: Downloaded .tar.gz files in app-archives/files/
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../../exports/app-archives"
URLS_FILE="${OUTPUT_DIR}/urls.txt"
FILES_DIR="${OUTPUT_DIR}/files"
LOG_FILE="${OUTPUT_DIR}/download.log"
FAILED_FILE="${OUTPUT_DIR}/failed.txt"

echo "=============================================="
echo "Downloading App Archives"
echo "=============================================="

# Check if urls.txt exists
if [ ! -f "${URLS_FILE}" ]; then
    echo "ERROR: ${URLS_FILE} not found!"
    echo "Run 01-extract-urls.sh first."
    exit 1
fi

# Create directories
mkdir -p "${FILES_DIR}"
> "${LOG_FILE}"
> "${FAILED_FILE}"

TOTAL=$(wc -l < "${URLS_FILE}" | tr -d ' ')
CURRENT=0
SUCCESS=0
FAILED=0

echo "Total URLs to download: ${TOTAL}"
echo "Output directory: ${FILES_DIR}"
echo ""

while IFS= read -r url; do
    CURRENT=$((CURRENT + 1))
    
    # Skip empty lines
    [ -z "$url" ] && continue
    
    # Extract filename from URL
    FILENAME=$(basename "$url")
    FILEPATH="${FILES_DIR}/${FILENAME}"
    
    echo "[${CURRENT}/${TOTAL}] Downloading: ${FILENAME}"
    
    # Skip if already downloaded
    if [ -f "${FILEPATH}" ]; then
        echo "  → Already exists, skipping"
        SUCCESS=$((SUCCESS + 1))
        continue
    fi
    
    # Download with curl
    if curl -fsSL -o "${FILEPATH}" "${url}" 2>>"${LOG_FILE}"; then
        echo "  → Success ($(du -h "${FILEPATH}" | cut -f1))"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "  → FAILED"
        echo "${url}" >> "${FAILED_FILE}"
        FAILED=$((FAILED + 1))
        rm -f "${FILEPATH}"
    fi
    
    # Small delay to avoid rate limiting
    sleep 0.2
    
done < "${URLS_FILE}"

# Calculate total size
TOTAL_SIZE=$(du -sh "${FILES_DIR}" 2>/dev/null | cut -f1 || echo "0")

echo ""
echo "=============================================="
echo "Download Complete!"
echo "=============================================="
echo "Successful: ${SUCCESS}"
echo "Failed: ${FAILED}"
echo "Total size: ${TOTAL_SIZE}"
echo "Files location: ${FILES_DIR}"
if [ ${FAILED} -gt 0 ]; then
    echo "Failed URLs: ${FAILED_FILE}"
fi
echo ""
echo "Next step: Run 03-update-db-urls.sh to update database"
echo "=============================================="
