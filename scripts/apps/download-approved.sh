#!/usr/bin/env bash
# =============================================================================
# download-approved.sh — Download approved, compatible app packages
# =============================================================================
# Downloads only apps that are:
#   - In the allowlist (or all apps if allowlist is empty)
#   - Compatible with NEXTCLOUD_VERSION
# Generates SHA-256 checksums for each downloaded archive.
#
# Usage:
#   ./scripts/apps/download-approved.sh [--nc-version X.Y.Z] [--force]
#
# Outputs:
#   exports/app-archives/files/*.tar.gz
#   exports/app-archives/CHECKSUMS.sha256
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"
ALLOWLIST="${PROJECT_DIR}/config/app-allowlist.txt"
ARCHIVES_DIR="${PROJECT_DIR}/exports/app-archives/files"
CHECKSUMS_FILE="${PROJECT_DIR}/exports/app-archives/CHECKSUMS.sha256"

if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

NC_VERSION="${NEXTCLOUD_VERSION:-}"
FORCE=false

for arg in "$@"; do
    case "${arg}" in
        --nc-version=*)  NC_VERSION="${arg#*=}" ;;
        --nc-version)    shift; NC_VERSION="${1:-}" ;;
        --force)         FORCE=true ;;
    esac
done

[ -n "${NC_VERSION}" ] || error "NEXTCLOUD_VERSION not set. Set in .env or pass --nc-version X.Y.Z"

require_running_appstore() {
    docker compose -f "${PROJECT_DIR}/docker-compose.yml" ps appstore \
        2>/dev/null | grep -qE "Up|running" \
        || error "App Store container not running. Start with: ./scripts/appstorectl.sh online up"
}

read_allowlist() {
    if [ -f "${ALLOWLIST}" ]; then
        grep -v '^\s*#' "${ALLOWLIST}" | grep -v '^\s*$' || true
    fi
}

sha256_file() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        error "sha256sum or shasum not found"
    fi
}

require_running_appstore

APPROVED_APPS="$(read_allowlist)"
APPROVED_CSV="$(echo "${APPROVED_APPS}" | tr '\n' ',' | sed 's/,$//')"

info "Fetching compatible app download URLs for Nextcloud ${NC_VERSION}..."

PYTHON_SCRIPT=$(cat <<'PYEOF'
import sys, json, os
from semantic_version import Version, Spec

nc_version_str = sys.argv[1]
approved_str   = sys.argv[2]

try:
    nc_version = Version(nc_version_str)
except ValueError:
    print(f"ERROR: Invalid version {nc_version_str}", file=sys.stderr)
    sys.exit(1)

approved = set(x.strip() for x in approved_str.split(",") if x.strip()) if approved_str else None

import django
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "nextcloudappstore.settings.production")
django.setup()

from nextcloudappstore.core.models import App, AppRelease

results = []
for app in App.objects.all().order_by("id"):
    if approved and app.id not in approved:
        continue
    for release in AppRelease.objects.filter(app=app).order_by("-version"):
        spec_str = release.platform_version_spec.strip()
        try:
            if spec_str in ("*", "", ">=0.0.0"):
                compatible = True
            else:
                spec = Spec(spec_str)
                compatible = nc_version in spec
        except Exception:
            compatible = False
        if compatible and release.download:
            results.append({"app_id": app.id, "version": str(release.version), "url": release.download})
            break

print(json.dumps(results))
PYEOF
)

URLS_JSON=$(docker compose -f "${PROJECT_DIR}/docker-compose.yml" \
    exec -T appstore \
    bash -c "python3 -c $(printf '%q' "${PYTHON_SCRIPT}") '${NC_VERSION}' '${APPROVED_CSV}'" \
    2>/dev/null)

[ -n "${URLS_JSON}" ] || error "No download URLs returned."

TOTAL=$(echo "${URLS_JSON}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
info "Found ${TOTAL} compatible app releases to download."

mkdir -p "${ARCHIVES_DIR}"
: > "${CHECKSUMS_FILE}.tmp"

DOWNLOADED=0
SKIPPED=0
FAILED=0

while IFS= read -r entry; do
    APP_ID="$(echo "${entry}" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['app_id'])")"
    VERSION="$(echo "${entry}" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['version'])")"
    URL="$(echo "${entry}" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['url'])")"

    FNAME="$(basename "${URL}" | sed 's/?.*//')"
    DEST="${ARCHIVES_DIR}/${FNAME}"

    if [ -f "${DEST}" ] && [ "${FORCE}" = "false" ]; then
        CHECKSUM="$(sha256_file "${DEST}")"
        printf "  %-40s %s\n" "${APP_ID}" "SKIP (exists)"
        echo "${CHECKSUM}  ${FNAME}" >> "${CHECKSUMS_FILE}.tmp"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    printf "  %-40s " "${APP_ID} v${VERSION}..."
    if curl -fsSL --retry 3 --retry-delay 2 -o "${DEST}" "${URL}" 2>/dev/null; then
        CHECKSUM="$(sha256_file "${DEST}")"
        echo "${CHECKSUM}  ${FNAME}" >> "${CHECKSUMS_FILE}.tmp"
        echo "OK ($(du -sh "${DEST}" | cut -f1))"
        DOWNLOADED=$((DOWNLOADED + 1))
    else
        echo "FAIL"
        warn "Failed to download: ${URL}"
        FAILED=$((FAILED + 1))
    fi
done < <(echo "${URLS_JSON}" | python3 -c "
import json, sys
for item in json.load(sys.stdin):
    print(json.dumps(item))
")

# Finalize checksums file
sort "${CHECKSUMS_FILE}.tmp" > "${CHECKSUMS_FILE}"
rm -f "${CHECKSUMS_FILE}.tmp"

echo ""
info "Download complete:"
echo "  Downloaded : ${DOWNLOADED}"
echo "  Skipped    : ${SKIPPED} (already present)"
echo "  Failed     : ${FAILED}"
echo ""
info "Archives  : ${ARCHIVES_DIR}/"
info "Checksums : ${CHECKSUMS_FILE}"

[ "${FAILED}" -eq 0 ] || { warn "Some downloads failed — re-run or investigate."; exit 1; }
