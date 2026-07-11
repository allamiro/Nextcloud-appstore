#!/usr/bin/env bash
# =============================================================================
# generate-report.sh — Generate compatibility and export status report
# =============================================================================
# Produces COMPATIBILITY_REPORT.csv and COMPATIBILITY_REPORT.json covering
# all approved apps: version, NC compatibility, package URL, local file
# path, checksum, approval status, and export status.
#
# Usage:
#   ./scripts/apps/generate-report.sh [--nc-version X.Y.Z] [--output-dir DIR]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"
ALLOWLIST="${PROJECT_DIR}/config/app-allowlist.txt"
ARCHIVES_DIR="${PROJECT_DIR}/exports/app-archives/files"

if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

OUTPUT_DIR="${PROJECT_DIR}/exports"

for arg in "$@"; do
    case "${arg}" in
        --nc-version=*)  NEXTCLOUD_VERSION="${arg#*=}" ;;
        --nc-version)    shift; NEXTCLOUD_VERSION="${1:-}" ;;
        --output-dir=*)  OUTPUT_DIR="${arg#*=}" ;;
        --output-dir)    shift; OUTPUT_DIR="${1:-}" ;;
    esac
done

NC_VERSION="${NEXTCLOUD_VERSION:-}"
[ -n "${NC_VERSION}" ] || error "NEXTCLOUD_VERSION is not set. Set in .env or pass --nc-version X.Y.Z"

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

require_running_appstore
mkdir -p "${OUTPUT_DIR}"

APPROVED_APPS="$(read_allowlist)"
APPROVED_CSV="$(echo "${APPROVED_APPS}" | tr '\n' ',' | sed 's/,$//')"

info "Generating compatibility report for Nextcloud ${NC_VERSION}..."

PYTHON_SCRIPT=$(cat <<'PYEOF'
import sys
import json
import os
import hashlib
import re
from pathlib import Path

from semantic_version import Version, Spec

nc_version_str = sys.argv[1]
approved_str   = sys.argv[2]
archives_dir   = sys.argv[3]
file_server_url = sys.argv[4] if len(sys.argv) > 4 else ""

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

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()

def find_local(url, archives_dir):
    """Derive the local file path from the download URL."""
    if not url:
        return None, None
    # Last path component is the filename
    fname = url.rstrip("/").split("/")[-1]
    fpath = Path(archives_dir) / fname
    if fpath.exists():
        return str(fpath), sha256_file(str(fpath))
    return None, None

results = []
apps_qs = App.objects.all().order_by("id")
for app in apps_qs:
    if approved and app.id not in approved:
        continue

    app_name = ""
    try:
        app_name = app.name.get("en", app.id) if isinstance(app.name, dict) else str(app.name)
    except Exception:
        app_name = app.id

    best_release = None
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
        if compatible:
            best_release = release
            break

    download_url = best_release.download if best_release else None
    platform_spec = best_release.platform_version_spec.strip() if best_release else None
    release_version = str(best_release.version) if best_release else None

    local_path, checksum = find_local(download_url, archives_dir)

    # Determine export status
    if not best_release:
        export_status = "no_compatible_release"
    elif local_path:
        export_status = "downloaded"
    else:
        export_status = "missing_archive"

    results.append({
        "app_id":            app.id,
        "app_name":          app_name,
        "release_version":   release_version,
        "platform_spec":     platform_spec,
        "nc_target":         nc_version_str,
        "is_compatible":     best_release is not None,
        "download_url":      download_url,
        "local_path":        local_path,
        "checksum_sha256":   checksum,
        "is_approved":       True,
        "export_status":     export_status,
    })

print(json.dumps(results, indent=2))
PYEOF
)

RESULTS=$(docker compose -f "${PROJECT_DIR}/docker-compose.yml" \
    exec -T appstore \
    bash -c "python3 -c $(printf '%q' "${PYTHON_SCRIPT}") \
        '${NC_VERSION}' \
        '${APPROVED_CSV}' \
        '${ARCHIVES_DIR}' \
        '${FILE_SERVER_URL:-}'" \
    2>/dev/null)

[ -n "${RESULTS}" ] || error "No results from report generation."

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
JSON_OUT="${OUTPUT_DIR}/COMPATIBILITY_REPORT.json"
CSV_OUT="${OUTPUT_DIR}/COMPATIBILITY_REPORT.csv"

# Save JSON
echo "${RESULTS}" > "${JSON_OUT}"

# Convert to CSV
echo "${RESULTS}" | python3 -c "
import json, sys, csv

data = json.load(sys.stdin)
fields = ['app_id','app_name','release_version','platform_spec','nc_target',
          'is_compatible','download_url','local_path','checksum_sha256','is_approved','export_status']

w = csv.DictWriter(sys.stdout, fieldnames=fields)
w.writeheader()
for row in data:
    w.writerow({k: row.get(k,'') for k in fields})
" > "${CSV_OUT}"

# Print summary
echo "${RESULTS}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
total       = len(data)
compat      = sum(1 for r in data if r['is_compatible'])
downloaded  = sum(1 for r in data if r['export_status'] == 'downloaded')
missing     = sum(1 for r in data if r['export_status'] == 'missing_archive')
no_release  = sum(1 for r in data if r['export_status'] == 'no_compatible_release')

print(f'  Nextcloud target    : ${NC_VERSION}')
print(f'  Approved apps       : {total}')
print(f'  Compatible releases : {compat}')
print(f'  Downloaded locally  : {downloaded}')
print(f'  Missing archive     : {missing}')
print(f'  No compatible rel.  : {no_release}')

if missing:
    print()
    print('  Apps missing local archive (run download-approved.sh):')
    for r in data:
        if r['export_status'] == 'missing_archive':
            print(f\"    {r['app_id']}\")
"

info "Report saved to: ${JSON_OUT}"
info "CSV saved to   : ${CSV_OUT}"
