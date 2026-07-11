#!/usr/bin/env bash
# =============================================================================
# export-bundle.sh — Build a complete air-gapped deployment bundle
# =============================================================================
# Creates a fully self-contained package with:
#   - VERSION.txt          (human-readable export manifest)
#   - MANIFEST.json        (machine-readable manifest)
#   - COMPATIBILITY_REPORT.csv / .json
#   - CHECKSUMS.sha256     (checksums of all bundle files)
#   - ALLOWLIST.txt        (copy of approved apps list)
#   - appstore_db_<ts>.sql.gz
#   - Docker images in airgapped/images/
#   - App archives in airgapped/exports/app-archives/
#
# Usage:
#   ./scripts/export-bundle.sh [--nc-version X.Y.Z] [--output-dir DIR] [--skip-images]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
ALLOWLIST="${PROJECT_DIR}/config/app-allowlist.txt"

if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
step()  { echo ""; echo "[${1}] ${2}"; }

NC_VERSION="${NEXTCLOUD_VERSION:-}"
OUTPUT_DIR="${PROJECT_DIR}"
SKIP_IMAGES=false
AIRGAP_DIR="${PROJECT_DIR}/airgapped"
AIRGAP_IMAGE_DIR="${AIRGAP_IMAGE_DIR:-${AIRGAP_DIR}/images}"
AIRGAP_EXPORT_DIR="${AIRGAP_EXPORT_DIR:-${AIRGAP_DIR}/exports}"
ARCHIVES_DIR="${AIRGAP_EXPORT_DIR}/app-archives/files"
CHECKSUMS_FILE="${AIRGAP_EXPORT_DIR}/app-archives/CHECKSUMS.sha256"

for arg in "$@"; do
    case "${arg}" in
        --nc-version=*)  NC_VERSION="${arg#*=}" ;;
        --nc-version)    shift; NC_VERSION="${1:-}" ;;
        --output-dir=*)  OUTPUT_DIR="${arg#*=}" ;;
        --output-dir)    shift; OUTPUT_DIR="${1:-}" ;;
        --skip-images)   SKIP_IMAGES=true ;;
    esac
done

[ -n "${NC_VERSION}" ] || error "NEXTCLOUD_VERSION not set. Set in .env or pass --nc-version X.Y.Z"

sha256_file() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        error "sha256sum or shasum not found"
    fi
}

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
EXPORT_DIR="${AIRGAP_EXPORT_DIR}"
mkdir -p "${EXPORT_DIR}" "${AIRGAP_IMAGE_DIR}"

echo "============================================================"
info "Building export bundle for Nextcloud ${NC_VERSION}"
echo "  Timestamp : ${TIMESTAMP}"
echo "  Output    : ${OUTPUT_DIR}/"
echo "============================================================"

# ── Step 1: Compatibility report ──────────────────────────────────────────────
step "1/7" "Generating compatibility report..."
bash "${SCRIPT_DIR}/apps/generate-report.sh" --nc-version "${NC_VERSION}" \
    --output-dir "${EXPORT_DIR}"

# ── Step 2: Download missing approved apps ────────────────────────────────────
step "2/7" "Downloading missing approved app archives..."
bash "${SCRIPT_DIR}/apps/download-approved.sh" --nc-version "${NC_VERSION}"

# ── Step 3: Export database ───────────────────────────────────────────────────
step "3/7" "Exporting database..."
bash "${SCRIPT_DIR}/db/export-db.sh"
LATEST_DUMP="$(find "${PROJECT_DIR}/exports" -maxdepth 1 -name 'appstore_db_*.sql.gz' \
    2>/dev/null | sort -r | head -1 || true)"
if [ -n "${LATEST_DUMP}" ]; then
    cp "${LATEST_DUMP}" "${EXPORT_DIR}/"
    info "DB dump: $(basename "${LATEST_DUMP}")"
else
    warn "No DB dump found — did db/export-db.sh run successfully?"
fi

# ── Step 4: Save Docker images ────────────────────────────────────────────────
step "4/7" "Saving Docker images..."
if [ "${SKIP_IMAGES}" = "true" ]; then
    info "Skipping image save (--skip-images)"
else
    IMAGES=("nextcloudappstore:latest" "postgres:15-alpine" "nginx:alpine")
    if [ "${INCLUDE_MANAGED_NEXTCLOUD_IMAGES:-false}" = "true" ]; then
        IMAGES+=("nextcloud:stable-apache")
    fi
    for img in "${IMAGES[@]}"; do
        SAFE="$(echo "${img}" | tr ':/' '__')"
        OUT="${AIRGAP_IMAGE_DIR}/${SAFE}_${TIMESTAMP}.tar.gz"
        if [ "${img}" != "nextcloudappstore:latest" ]; then
            docker pull "${img}" 2>/dev/null || warn "Could not pull ${img} — using cached version"
        fi
        info "  Saving ${img}..."
        docker save "${img}" | gzip -c > "${OUT}"
        sha256_file "${OUT}" > "${OUT}.sha256"
        info "  Saved: $(basename "${OUT}") ($(du -sh "${OUT}" | cut -f1))"
    done
fi

# ── Step 5: Collect statistics ────────────────────────────────────────────────
step "5/7" "Collecting bundle statistics..."

REPORT_JSON="${EXPORT_DIR}/COMPATIBILITY_REPORT.json"
if [ -f "${REPORT_JSON}" ]; then
    TOTAL_APPROVED=$(python3 -c "import json; d=json.load(open('${REPORT_JSON}')); print(len(d))")
    TOTAL_COMPAT=$(python3 -c "import json; d=json.load(open('${REPORT_JSON}')); print(sum(1 for r in d if r['is_compatible']))")
    TOTAL_EXPORTED=$(python3 -c "import json; d=json.load(open('${REPORT_JSON}')); print(sum(1 for r in d if r['export_status']=='downloaded'))")
else
    TOTAL_APPROVED=0
    TOTAL_COMPAT=0
    TOTAL_EXPORTED=0
fi

ARCHIVE_COUNT=$(find "${ARCHIVES_DIR}" -name '*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
ARCHIVE_SIZE=$(du -sh "${ARCHIVES_DIR}" 2>/dev/null | cut -f1 || echo "0")
IMAGE_COUNT=$(find "${AIRGAP_IMAGE_DIR}" -name '*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
IMAGE_SIZE=$(du -sh "${AIRGAP_IMAGE_DIR}" 2>/dev/null | cut -f1 || echo "0")
HOSTNAME="$(hostname 2>/dev/null || echo "unknown")"
APPSTORE_VER="${APPSTORE_VERSION:-master}"

# ── Step 6: Write VERSION.txt and MANIFEST.json ───────────────────────────────
step "6/7" "Writing VERSION.txt and MANIFEST.json..."

cat > "${EXPORT_DIR}/VERSION.txt" <<EOF
# Nextcloud App Store — Air-Gapped Export Manifest
EXPORT_TIMESTAMP=${TIMESTAMP}
APPSTORE_VERSION=${APPSTORE_VER}
NEXTCLOUD_VERSION=${NC_VERSION}
NEXTCLOUD_MAJOR_VERSION=$(echo "${NC_VERSION}" | cut -d. -f1)
TOTAL_APPROVED_APPS=${TOTAL_APPROVED}
COMPATIBLE_APPS=${TOTAL_COMPAT}
EXPORTED_PACKAGES=${TOTAL_EXPORTED}
ARCHIVE_COUNT=${ARCHIVE_COUNT}
ARCHIVE_SIZE_MB=${ARCHIVE_SIZE}
DOCKER_IMAGE_COUNT=${IMAGE_COUNT}
DOCKER_IMAGE_SIZE=${IMAGE_SIZE}
EXPORT_HOST=${HOSTNAME}
APPSTORE_API_URL=${APPSTORE_API_URL:-}
FILE_SERVER_URL=${FILE_SERVER_URL:-}
EOF

python3 - <<PYEOF
import json
manifest = {
    "export_timestamp":       "${TIMESTAMP}",
    "appstore_version":       "${APPSTORE_VER}",
    "nextcloud_version":      "${NC_VERSION}",
    "nextcloud_major_version": "${NC_VERSION}".split(".")[0],
    "total_approved_apps":    ${TOTAL_APPROVED},
    "compatible_apps":        ${TOTAL_COMPAT},
    "exported_packages":      ${TOTAL_EXPORTED},
    "archive_count":          ${ARCHIVE_COUNT},
    "docker_image_count":     ${IMAGE_COUNT},
    "export_host":            "${HOSTNAME}",
    "appstore_api_url":       "${APPSTORE_API_URL:-}",
    "file_server_url":        "${FILE_SERVER_URL:-}",
}
with open("${EXPORT_DIR}/MANIFEST.json", "w") as f:
    json.dump(manifest, f, indent=2)
print("  MANIFEST.json written")
PYEOF

# Copy current allowlist into bundle
cp "${ALLOWLIST}" "${EXPORT_DIR}/ALLOWLIST.txt" 2>/dev/null || true
# Copy compatibility report CSV into bundle
cp "${PROJECT_DIR}/exports/COMPATIBILITY_REPORT.csv" "${EXPORT_DIR}/" 2>/dev/null || true
cp "${PROJECT_DIR}/exports/COMPATIBILITY_REPORT.json" "${EXPORT_DIR}/" 2>/dev/null || true

# ── Step 7: Generate top-level CHECKSUMS.sha256 ───────────────────────────────
step "7/7" "Generating checksums..."

CHECKSUMS_OUT="${EXPORT_DIR}/CHECKSUMS.sha256"
: > "${CHECKSUMS_OUT}"

for f in \
    "${EXPORT_DIR}/VERSION.txt" \
    "${EXPORT_DIR}/MANIFEST.json" \
    "${EXPORT_DIR}/ALLOWLIST.txt" \
    "${EXPORT_DIR}/COMPATIBILITY_REPORT.csv" \
    "${EXPORT_DIR}/COMPATIBILITY_REPORT.json"; do
    [ -f "${f}" ] || continue
    echo "$(sha256_file "${f}")  $(basename "${f}")" >> "${CHECKSUMS_OUT}"
done

# Include DB dump checksum
LATEST_AIRGAP_DUMP="$(find "${EXPORT_DIR}" -maxdepth 1 -name 'appstore_db_*.sql.gz' \
    2>/dev/null | sort -r | head -1 || true)"
if [ -n "${LATEST_AIRGAP_DUMP}" ]; then
    echo "$(sha256_file "${LATEST_AIRGAP_DUMP}")  $(basename "${LATEST_AIRGAP_DUMP}")" >> "${CHECKSUMS_OUT}"
fi

# ── Create final bundle tarball ───────────────────────────────────────────────
PKG="${OUTPUT_DIR}/nextcloud-appstore-airgap-${TIMESTAMP}.tar.gz"
info "Creating bundle tarball..."
tar -czf "${PKG}" \
    -C "${PROJECT_DIR}" \
    airgapped/ k8s/ config/ nginx/ fileserver/ scripts/ \
    Dockerfile docker-entrypoint.sh docker-compose.yml .env.example

PKG_SIZE="$(du -sh "${PKG}" | cut -f1)"

echo ""
echo "============================================================"
info "Export bundle complete"
echo ""
echo "  Bundle tarball : ${PKG} (${PKG_SIZE})"
echo "  Exports dir    : ${EXPORT_DIR}/"
echo "  Images dir     : ${AIRGAP_IMAGE_DIR}/"
echo "  App archives   : ${ARCHIVES_DIR}/ (${ARCHIVE_COUNT} packages)"
echo ""
echo "  Approved apps  : ${TOTAL_APPROVED}"
echo "  Compatible     : ${TOTAL_COMPAT} (for NC ${NC_VERSION})"
echo "  Exported       : ${TOTAL_EXPORTED}"
echo ""
echo "  MANIFEST.json  : ${EXPORT_DIR}/MANIFEST.json"
echo "  CHECKSUMS      : ${CHECKSUMS_OUT}"
echo "============================================================"
