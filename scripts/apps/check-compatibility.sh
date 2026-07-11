#!/usr/bin/env bash
# =============================================================================
# check-compatibility.sh — Check app compatibility against a Nextcloud version
# =============================================================================
# Queries the App Store database and checks each approved app's releases
# against the target Nextcloud version using semantic_version.
#
# Usage:
#   ./scripts/apps/check-compatibility.sh [--nc-version X.Y.Z]
#
# Environment variables (can be set in .env):
#   NEXTCLOUD_VERSION       Target NC version (e.g. 30.0.1)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "${SCRIPT_DIR}")")"
ALLOWLIST="${PROJECT_DIR}/config/app-allowlist.txt"

if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# Allow --nc-version override
for arg in "$@"; do
    case "${arg}" in
        --nc-version=*) NEXTCLOUD_VERSION="${arg#*=}" ;;
        --nc-version)   shift; NEXTCLOUD_VERSION="${1:-}" ;;
    esac
done

NC_VERSION="${NEXTCLOUD_VERSION:-}"
if [ -z "${NC_VERSION}" ]; then
    error "NEXTCLOUD_VERSION is not set. Set it in .env or pass --nc-version X.Y.Z"
fi

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

info "Checking app compatibility against Nextcloud ${NC_VERSION}"
echo ""

APPROVED_APPS="$(read_allowlist)"

# Build the Python compatibility check script
PYTHON_SCRIPT=$(cat <<'PYEOF'
import sys
import json
import re

# semantic_version is a dependency of the Nextcloud App Store
from semantic_version import Version, Spec

nc_version_str = sys.argv[1]
approved_str = sys.argv[2]  # comma-separated list, or empty string for all

try:
    nc_version = Version(nc_version_str)
except ValueError:
    print(f"ERROR: Invalid Nextcloud version: {nc_version_str}", file=sys.stderr)
    sys.exit(1)

approved = set(x.strip() for x in approved_str.split(",") if x.strip()) if approved_str else None

import django
import os
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "nextcloudappstore.settings.production")
django.setup()

from nextcloudappstore.core.models import App, AppRelease

results = []
apps_qs = App.objects.all().order_by("id")
for app in apps_qs:
    if approved and app.id not in approved:
        continue

    best_release = None
    best_version = None

    for release in AppRelease.objects.filter(app=app).order_by("-version"):
        spec_str = release.platform_version_spec.strip()
        try:
            if spec_str in ("*", "", ">=0.0.0"):
                compatible = True
            else:
                # Convert Nextcloud spec format (>=X.Y.Z,<A.B.C) to semantic_version Spec
                spec = Spec(spec_str)
                compatible = nc_version in spec
        except Exception:
            compatible = False

        if compatible:
            best_release = release
            try:
                best_version = Version(str(release.version))
            except Exception:
                best_version = None
            break

    results.append({
        "app_id": app.id,
        "app_name": app.name.get("en", app.id) if hasattr(app.name, "get") else str(app.name),
        "latest_compatible_version": str(best_release.version) if best_release else None,
        "platform_spec": best_release.platform_version_spec.strip() if best_release else None,
        "download_url": best_release.download if best_release else None,
        "is_compatible": best_release is not None,
        "is_approved": True,
    })

print(json.dumps(results, indent=2))
PYEOF
)

APPROVED_CSV="$(echo "${APPROVED_APPS}" | tr '\n' ',' | sed 's/,$//')"

RESULTS=$(docker compose -f "${PROJECT_DIR}/docker-compose.yml" \
    exec -T appstore \
    bash -c "python3 -c $(printf '%q' "${PYTHON_SCRIPT}") '${NC_VERSION}' '${APPROVED_CSV}'" \
    2>/dev/null)

if [ -z "${RESULTS}" ]; then
    error "No results returned from compatibility check. Is the database populated?"
fi

# Display results
echo "${RESULTS}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
compat = [r for r in data if r['is_compatible']]
incompat = [r for r in data if not r['is_compatible']]

print(f'  Total approved apps : {len(data)}')
print(f'  Compatible          : {len(compat)}')
print(f'  Not compatible      : {len(incompat)}')
print()

if compat:
    print('  COMPATIBLE apps:')
    for r in compat:
        print(f\"    {r['app_id']:<35} v{r['latest_compatible_version']:<12} {r['platform_spec']}\")

if incompat:
    print()
    print('  NOT COMPATIBLE apps:')
    for r in incompat:
        print(f\"    {r['app_id']:<35} no release for NC ${NC_VERSION}\")
"

# Save JSON output for downstream scripts
OUT_DIR="${PROJECT_DIR}/exports"
mkdir -p "${OUT_DIR}"
OUT_FILE="${OUT_DIR}/compatibility_${NC_VERSION//./_}.json"
echo "${RESULTS}" > "${OUT_FILE}"
info "Compatibility data saved to: ${OUT_FILE}"
