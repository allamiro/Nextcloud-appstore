#!/bin/bash
# =============================================================================
# Sync Apps from Official Nextcloud App Store
# =============================================================================
# Imports all apps from https://apps.nextcloud.com into the local App Store.
# Run on the staging server (with internet) before exporting for air-gapped
# deployment.
#
# Usage:
#   ./scripts/sync-apps.sh              # Sync all apps across all platforms
#   ./scripts/sync-apps.sh --limit 10   # Sync first 10 apps (test run)
#
# Environment:
#   APPSTORE_SYNC_PLATFORMS  Comma-separated platform versions to fetch.
#                            Default: "30.0.0,33.0.0"
#                            Example: APPSTORE_SYNC_PLATFORMS=30.0.0,31.0.0,33.0.0
#
# Note: --limit uses the SAME code path as a full sync. The full platform list
# is merged first, then the first N apps are processed. This ensures --limit
# tests the real sync behaviour rather than different logic.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

LIMIT_VAL=""
if [ "${1:-}" = "--limit" ]; then
    LIMIT_VAL="${2:-10}"
fi

# Platforms to fetch — comma-separated, no spaces.
# Expand the list here (or via env) to include any NC version your users run.
RAW_PLATFORMS="${APPSTORE_SYNC_PLATFORMS:-30.0.0,33.0.0}"

echo "=============================================="
echo "Nextcloud App Store - App Sync"
echo "=============================================="
echo ""
echo "Platforms : ${RAW_PLATFORMS}"
if [ -n "${LIMIT_VAL}" ]; then
    echo "Limit     : first ${LIMIT_VAL} apps (test run)"
fi
echo ""

# Check if the appstore container is running.
# Use docker inspect rather than 'docker compose ps' so the check works
# regardless of which compose files were used to start the stack (the macOS
# overlay uses a different file set and 'docker compose ps' without those
# flags would not see the running container).
APPSTORE_CONTAINER="${APPSTORE_CONTAINER_NAME:-appstore-app}"
if ! docker inspect "${APPSTORE_CONTAINER}" --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
    echo "Error: appstore container '${APPSTORE_CONTAINER}' is not running"
    echo "Start it with: ./scripts/appstorectl.sh online up"
    exit 1
fi

# Build the platform list as a Python list literal for the heredoc
PY_PLATFORMS="[$(echo "${RAW_PLATFORMS}" | sed 's/,/", "/g' | sed 's/^/"/;s/$/"/' )]"

# Build the optional slice expression
if [ -n "${LIMIT_VAL}" ]; then
    PY_SLICE=":${LIMIT_VAL}"
else
    PY_SLICE=""
fi

echo "Syncing apps from official Nextcloud App Store..."
echo "This may take 5–15 minutes depending on your connection speed..."

docker exec -i "${APPSTORE_CONTAINER}" python manage.py shell <<PYEOF
import requests
from django.db import transaction
from django.contrib.auth import get_user_model
from nextcloudappstore.core.models import App, AppRelease, Category, Screenshot

User = get_user_model()
system_user, _ = User.objects.get_or_create(
    username='appstore-import',
    defaults={'email': 'import@localhost', 'is_active': False}
)
print(f"Using system user: {system_user.username}")

# Fetch apps for every configured platform and merge by app ID so all
# compatible releases are captured. This is the single code path used
# for both full syncs and --limit test runs.
PLATFORMS = ${PY_PLATFORMS}
apps_by_id = {}
for _pver in PLATFORMS:
    print(f"Fetching apps for platform {_pver}...")
    try:
        _r = requests.get(
            f"https://apps.nextcloud.com/api/v1/platform/{_pver}/apps.json",
            timeout=120
        )
        _r.raise_for_status()
    except requests.RequestException as exc:
        print(f"  WARNING: failed to fetch platform {_pver}: {exc}")
        continue
    _data = _r.json()
    if not isinstance(_data, list):
        print(f"  WARNING: unexpected response type for {_pver}: {type(_data).__name__}, skipping")
        continue
    for _a in _data:
        _aid = _a.get('id')
        if not _aid or not isinstance(_aid, str):
            continue
        if _aid not in apps_by_id:
            apps_by_id[_aid] = _a
        else:
            _seen = {r['version']: r for r in apps_by_id[_aid].get('releases', []) if r.get('version')}
            for _rel in _a.get('releases', []):
                _v = _rel.get('version')
                if _v and _v not in _seen:
                    _seen[_v] = _rel
            apps_by_id[_aid]['releases'] = list(_seen.values())

all_apps = list(apps_by_id.values())
apps = all_apps${PY_SLICE}
print(f"Found {len(all_apps)} unique apps across platforms: {', '.join(PLATFORMS)}")
if apps is not all_apps:
    print(f"Processing first {len(apps)} apps (--limit test run)")

imported = 0
translations_added = 0
screenshots_added = 0

for i, app_data in enumerate(apps, 1):
    app_id = app_data.get('id')
    if not app_id or not isinstance(app_id, str):
        continue
    try:
        with transaction.atomic():
            app, created = App.objects.get_or_create(
                id=app_id,
                defaults={'owner': system_user}
            )

            # Categories
            for cat_id in app_data.get('categories', []):
                try:
                    app.categories.add(Category.objects.get(id=cat_id))
                except Category.DoesNotExist:
                    pass  # unknown category — skip silently

            # App metadata
            app.website = app_data.get('website', '') or ''
            app.user_docs = app_data.get('userDocs', '') or ''
            app.admin_docs = app_data.get('adminDocs', '') or ''
            app.developer_docs = app_data.get('developerDocs', '') or ''
            app.issue_tracker = app_data.get('issueTracker', '') or ''
            if app_data.get('certificate') and not app.certificate:
                app.certificate = app_data['certificate']
            app.save()

            # English translations
            translations = app_data.get('translations', {})
            if 'en' in translations and not app.translations.filter(language_code='en').exists():
                en = translations['en']
                app.set_current_language('en')
                app.name = en.get('name', app_id)
                app.summary = en.get('summary', '')
                app.description = en.get('description', '')
                app.save()
                translations_added += 1

            # Screenshots
            for idx, ss in enumerate(app_data.get('screenshots', [])):
                url = ss.get('url', '')
                if url and not Screenshot.objects.filter(app=app, url=url).exists():
                    Screenshot.objects.create(
                        app=app,
                        url=url,
                        small_thumbnail=ss.get('smallThumbnail', ''),
                        ordering=idx
                    )
                    screenshots_added += 1

            # Releases
            for rel in app_data.get('releases', []):
                ver = rel.get('version')
                if not ver:
                    continue
                if AppRelease.objects.filter(app=app, version=ver).exists():
                    continue
                raw_platform = rel.get('rawPlatformVersionSpec', '') or ''
                raw_php = rel.get('rawPhpVersionSpec', '') or '*'
                platform_spec = rel.get('platformVersionSpec', '') or ''
                if ' ' in platform_spec and ',' not in platform_spec:
                    platform_spec = platform_spec.replace(' ', ',')
                if not raw_platform:
                    raw_platform = platform_spec.replace(',', ' ')
                AppRelease.objects.create(
                    app=app,
                    version=ver,
                    platform_version_spec=platform_spec,
                    php_version_spec='',
                    raw_platform_version_spec=raw_platform,
                    raw_php_version_spec=raw_php,
                    download=rel.get('download', ''),
                    signature=rel.get('signature', ''),
                    is_nightly=rel.get('isNightly', False),
                )

            if created:
                imported += 1
            if i % 50 == 0:
                print(f"Progress: {i}/{len(apps)}")
    except Exception as e:
        print(f"Error with {app_id}: {e}")

print(f"\nSync complete!")
print(f"New apps imported: {imported}")
print(f"Translations added: {translations_added}")
print(f"Screenshots added: {screenshots_added}")
print(f"Total apps: {App.objects.count()}")
print(f"Total releases: {AppRelease.objects.count()}")
print(f"Total screenshots: {Screenshot.objects.count()}")
PYEOF

echo ""
echo "Done! You can now export the database with: ./scripts/appstorectl.sh online export-db"
