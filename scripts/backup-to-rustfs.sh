#!/usr/bin/env bash
# =============================================================================
# backup-to-rustfs.sh — Upload backups and bundles to RustFS object storage
# =============================================================================
# RustFS is an S3-compatible object store that runs alongside the App Store
# stack. This script uploads files to three buckets:
#
#   app-archives  — mirrored app .tar.gz packages  (public-read — nginx serves from here)
#   backups       — App Store PostgreSQL dumps      (private)
#   bundles       — air-gapped export bundle tarballs + manifests (private)
#
# Buckets are created automatically on first run if they don't exist.
# Uses minio/mc in a temporary Docker container — nothing extra to install.
#
# Usage:
#   ./scripts/backup-to-rustfs.sh db              Upload latest DB dump → backups
#   ./scripts/backup-to-rustfs.sh apps            Upload all app archives → app-archives
#   ./scripts/backup-to-rustfs.sh bundle          Upload latest bundle tarball → bundles
#   ./scripts/backup-to-rustfs.sh all             Run all three
#   ./scripts/backup-to-rustfs.sh ls [bucket]     List bucket contents
#   ./scripts/backup-to-rustfs.sh init            Create/verify buckets only
#
# Environment (.env):
#   RUSTFS_HOST         — IP/hostname of the RustFS server (default: 192.168.178.165)
#   RUSTFS_PORT         — S3 API port (default: 9000)
#   RUSTFS_ACCESS_KEY   — access key (default: rustfsadmin)
#   RUSTFS_SECRET_KEY   — secret key (must be set)
#   USE_RUSTFS          — set to true to enable auto-upload from other scripts
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "${PROJECT_DIR}/.env"
    set +a
fi

# ── Configuration from .env ────────────────────────────────────────────────
RUSTFS_HOST="${RUSTFS_HOST:-192.168.178.165}"
RUSTFS_PORT="${RUSTFS_PORT:-9000}"
RUSTFS_ACCESS_KEY="${RUSTFS_ACCESS_KEY:-rustfsadmin}"
RUSTFS_SECRET_KEY="${RUSTFS_SECRET_KEY:-ChangeThisPassword}"
RUSTFS_ENDPOINT="http://${RUSTFS_HOST}:${RUSTFS_PORT}"
AIRGAP_EXPORT_DIR="${AIRGAP_EXPORT_DIR:-${PROJECT_DIR}/airgapped/exports}"
ARCHIVES_DIR="${AIRGAP_EXPORT_DIR}/app-archives/files"

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# ── mc wrapper — runs minio/mc as a disposable container ──────────────────
# Uses the actual RUSTFS_HOST so it works whether called from the host
# or in any script context. No --network flag needed since we go via the
# publicly-mapped port.
_mc() {
    docker run --rm \
        -e "MC_HOST_appstore=${RUSTFS_ENDPOINT}/${RUSTFS_ACCESS_KEY}:${RUSTFS_SECRET_KEY}" \
        minio/mc:latest "$@" 2>/dev/null
}

# Correct mc alias format: http://user:pass@host:port
_mc_alias() {
    docker run --rm \
        -e "MC_HOST_appstore=http://${RUSTFS_ACCESS_KEY}:${RUSTFS_SECRET_KEY}@${RUSTFS_HOST}:${RUSTFS_PORT}" \
        minio/mc:latest "$@"
}

# ── Health check ───────────────────────────────────────────────────────────
check_rustfs() {
    printf "Checking RustFS at %s..." "${RUSTFS_ENDPOINT}"
    if curl -fsS --max-time 8 "${RUSTFS_ENDPOINT}/minio/health/live" &>/dev/null; then
        echo " OK"
    else
        echo ""
        error "RustFS not reachable at ${RUSTFS_ENDPOINT}
  Make sure the stack is running: ./scripts/appstorectl.sh online up
  Check RUSTFS_HOST=${RUSTFS_HOST} and RUSTFS_PORT=${RUSTFS_PORT} in .env"
    fi
}

# ── Bucket initialisation ─────────────────────────────────────────────────
init_buckets() {
    info "Creating buckets (skipped if they already exist)..."

    docker run --rm \
        -e "MC_HOST_appstore=http://${RUSTFS_ACCESS_KEY}:${RUSTFS_SECRET_KEY}@${RUSTFS_HOST}:${RUSTFS_PORT}" \
        minio/mc:latest \
        /bin/sh -c "
          mc mb --ignore-existing appstore/app-archives &&
          mc mb --ignore-existing appstore/backups &&
          mc mb --ignore-existing appstore/bundles &&
          mc anonymous set download appstore/app-archives
        "

    ok "Buckets ready:"
    echo "  app-archives  (public-read — app packages)"
    echo "  backups       (private     — DB dumps)"
    echo "  bundles       (private     — export bundles)"
}

# ── Upload a single file ───────────────────────────────────────────────────
upload_file() {
    local src="$1"
    local bucket="$2"
    local remote_name="${3:-$(basename "${src}")}"

    [ -f "${src}" ] || { warn "File not found: ${src}"; return 1; }

    local size
    size="$(du -sh "${src}" | cut -f1)"
    printf "  %-52s %s " "$(basename "${src}")" "(${size})..."

    docker run --rm \
        -v "${src}:/upload/${remote_name}:ro" \
        -e "MC_HOST_appstore=http://${RUSTFS_ACCESS_KEY}:${RUSTFS_SECRET_KEY}@${RUSTFS_HOST}:${RUSTFS_PORT}" \
        minio/mc:latest \
        cp "/upload/${remote_name}" "appstore/${bucket}/${remote_name}" \
        &>/dev/null

    echo "uploaded"
}

# ── Sub-commands ───────────────────────────────────────────────────────────

cmd_init() {
    check_rustfs
    init_buckets
}

cmd_db() {
    info "Uploading DB backup → RustFS bucket: backups"
    check_rustfs
    init_buckets

    # Find the most recent dump in either exports location
    LATEST_DUMP="$(find "${AIRGAP_EXPORT_DIR}" "${PROJECT_DIR}/exports" \
        -maxdepth 1 -name 'appstore_db_*.sql.gz' 2>/dev/null | sort -r | head -1 || true)"

    [ -n "${LATEST_DUMP}" ] || error "No DB dump found. Run: ./scripts/appstorectl.sh online export-db"

    upload_file "${LATEST_DUMP}" "backups"
    ok "DB dump uploaded: $(basename "${LATEST_DUMP}")"
    echo "  Browse: http://${RUSTFS_HOST}:9001 → backups bucket"
}

cmd_apps() {
    info "Uploading app archives → RustFS bucket: app-archives"
    check_rustfs
    init_buckets

    [ -d "${ARCHIVES_DIR}" ] || error "No app archives found at ${ARCHIVES_DIR}
  Run: ./scripts/appstorectl.sh online apps mirror-approved --nc-version X.Y.Z"

    local count=0
    echo ""
    while IFS= read -r f; do
        [ -z "${f}" ] && continue
        upload_file "${f}" "app-archives"
        count=$((count + 1))
    done < <(find "${ARCHIVES_DIR}" -name '*.tar.gz' 2>/dev/null | sort)

    # Also upload the checksums file
    local checksums="${AIRGAP_EXPORT_DIR}/app-archives/CHECKSUMS.sha256"
    [ -f "${checksums}" ] && upload_file "${checksums}" "app-archives"

    echo ""
    ok "${count} app archive(s) uploaded."
    echo "  Browse: http://${RUSTFS_HOST}:9001 → app-archives bucket"
}

cmd_bundle() {
    info "Uploading export bundle → RustFS bucket: bundles"
    check_rustfs
    init_buckets

    LATEST_BUNDLE="$(find "${PROJECT_DIR}" -maxdepth 1 \
        -name 'nextcloud-appstore-airgap-*.tar.gz' 2>/dev/null | sort -r | head -1 || true)"

    [ -n "${LATEST_BUNDLE}" ] || error "No bundle found. Run: ./scripts/appstorectl.sh online export --nc-version X.Y.Z"

    upload_file "${LATEST_BUNDLE}" "bundles"

    # Upload all manifest/report files
    echo ""
    info "Uploading bundle metadata..."
    for meta_file in \
        "${AIRGAP_EXPORT_DIR}/MANIFEST.json" \
        "${AIRGAP_EXPORT_DIR}/VERSION.txt" \
        "${AIRGAP_EXPORT_DIR}/COMPATIBILITY_REPORT.csv" \
        "${AIRGAP_EXPORT_DIR}/COMPATIBILITY_REPORT.json" \
        "${AIRGAP_EXPORT_DIR}/CHECKSUMS.sha256" \
        "${AIRGAP_EXPORT_DIR}/ALLOWLIST.txt"; do
        [ -f "${meta_file}" ] && upload_file "${meta_file}" "bundles"
    done

    ok "Bundle uploaded: $(basename "${LATEST_BUNDLE}")"
    echo "  Browse: http://${RUSTFS_HOST}:9001 → bundles bucket"
}

cmd_all() {
    separator() { echo ""; echo "────────────────────────────────────────────────"; }

    cmd_db
    separator
    cmd_apps
    separator
    cmd_bundle

    echo ""
    ok "All uploads complete."
    echo "  Console: http://${RUSTFS_HOST}:9001"
    echo "  Login:   ${RUSTFS_ACCESS_KEY} / (RUSTFS_SECRET_KEY from .env)"
}

cmd_ls() {
    local bucket="${1:-}"
    check_rustfs
    echo ""
    if [ -n "${bucket}" ]; then
        info "Contents of ${bucket} bucket:"
        docker run --rm \
            -e "MC_HOST_appstore=http://${RUSTFS_ACCESS_KEY}:${RUSTFS_SECRET_KEY}@${RUSTFS_HOST}:${RUSTFS_PORT}" \
            minio/mc:latest \
            ls "appstore/${bucket}/"
    else
        info "RustFS buckets at ${RUSTFS_ENDPOINT}:"
        docker run --rm \
            -e "MC_HOST_appstore=http://${RUSTFS_ACCESS_KEY}:${RUSTFS_SECRET_KEY}@${RUSTFS_HOST}:${RUSTFS_PORT}" \
            minio/mc:latest \
            ls appstore/
    fi
}

# ── Entry point ────────────────────────────────────────────────────────────
COMMAND="${1:-}"
shift || true

case "${COMMAND}" in
    init)   cmd_init ;;
    db)     cmd_db ;;
    apps)   cmd_apps ;;
    bundle) cmd_bundle ;;
    all)    cmd_all ;;
    ls)     cmd_ls "$@" ;;
    "")
        cat <<EOF

Usage: $(basename "$0") <command> [bucket]

  init    Create buckets on RustFS (run once after first start)
  db      Upload latest App Store DB dump  → backups bucket
  apps    Upload all app archives          → app-archives bucket
  bundle  Upload latest export bundle      → bundles bucket
  all     Run init + db + apps + bundle
  ls      List all buckets (or: ls <bucket> to list contents)

RustFS console : http://${RUSTFS_HOST}:9001
S3 endpoint    : http://${RUSTFS_HOST}:${RUSTFS_PORT}
Credentials    : ${RUSTFS_ACCESS_KEY} / (RUSTFS_SECRET_KEY from .env)

Set USE_RUSTFS=true in .env to auto-upload after export-db and export.
EOF
        exit 1
        ;;
    *)
        error "Unknown command '${COMMAND}'. Use: init | db | apps | bundle | all | ls"
        ;;
esac
