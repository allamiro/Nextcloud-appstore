#!/bin/bash
# =============================================================================
# Sync Apps from Official Nextcloud App Store
# =============================================================================
# This script imports all apps from https://apps.nextcloud.com into your
# local App Store instance. Run this on the staging server (with internet)
# before exporting for air-gapped deployment.
#
# Usage:
#   ./scripts/sync-apps.sh              # Sync all apps
#   ./scripts/sync-apps.sh --limit 10   # Sync first 10 apps (testing)
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

LIMIT="${1:-}"

echo "=============================================="
echo "Nextcloud App Store - App Sync"
echo "=============================================="
echo ""

# Check if container is running
if ! docker-compose ps appstore | grep -q "Up"; then
    echo "Error: appstore container is not running"
    echo "Start it with: docker-compose up -d"
    exit 1
fi

# Run the sync using Django shell
if [ -n "$LIMIT" ] && [ "$LIMIT" == "--limit" ]; then
    LIMIT_VAL="${2:-10}"
    echo "Syncing apps with limit: $LIMIT_VAL"
    docker-compose exec -T appstore python manage.py shell <<EOF
import requests
from django.db import transaction
from django.contrib.auth import get_user_model
from nextcloudappstore.core.models import App, AppRelease, Category

User = get_user_model()
# Get or create a system user to own imported apps
system_user, _ = User.objects.get_or_create(
    username='appstore-import',
    defaults={'email': 'import@localhost', 'is_active': False}
)
print(f"Using system user: {system_user.username}")

print("Fetching apps from official store...")
resp = requests.get("https://apps.nextcloud.com/api/v1/apps.json", timeout=60)
apps = resp.json()[:$LIMIT_VAL]
print(f"Processing {len(apps)} apps...")

for i, app_data in enumerate(apps, 1):
    app_id = app_data.get('id')
    try:
        with transaction.atomic():
            app, created = App.objects.get_or_create(
                id=app_id,
                defaults={'owner': system_user}
            )
            for cat_id in app_data.get('categories', []):
                try:
                    app.categories.add(Category.objects.get(id=cat_id))
                except:
                    pass
            app.save()
            
            for rel in app_data.get('releases', []):
                ver = rel.get('version')
                if ver and not AppRelease.objects.filter(app=app, version=ver).exists():
                    # Fix platform spec format: space-separated -> comma-separated
                    platform_spec = rel.get('platformVersionSpec', '*')
                    if ' ' in platform_spec and ',' not in platform_spec:
                        platform_spec = platform_spec.replace(' ', ',')
                    php_spec = rel.get('phpVersionSpec', '*')
                    if ' ' in php_spec and ',' not in php_spec:
                        php_spec = php_spec.replace(' ', ',')
                    AppRelease.objects.create(
                        app=app,
                        version=ver,
                        platform_version_spec=platform_spec,
                        php_version_spec=php_spec,
                        download=rel.get('download', ''),
                        signature=rel.get('signature', ''),
                        is_nightly=rel.get('isNightly', False),
                    )
            status = "NEW" if created else "updated"
            print(f"[{i}] {app_id}: {status}")
    except Exception as e:
        print(f"[{i}] {app_id}: ERROR - {e}")

print(f"\nTotal apps: {App.objects.count()}")
print(f"Total releases: {AppRelease.objects.count()}")
EOF
else
    echo "Syncing ALL apps from official store..."
    echo "This may take several minutes..."
    docker-compose exec -T appstore python manage.py shell <<'EOF'
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

# Use platform-specific API which includes screenshots and translations
print("Fetching apps from official store (platform API)...")
resp = requests.get("https://apps.nextcloud.com/api/v1/platform/30.0.0/apps.json", timeout=120)
apps = resp.json()
print(f"Found {len(apps)} apps")

imported = 0
translations_added = 0
screenshots_added = 0

for i, app_data in enumerate(apps, 1):
    app_id = app_data.get('id')
    try:
        with transaction.atomic():
            app, created = App.objects.get_or_create(
                id=app_id,
                defaults={'owner': system_user}
            )
            
            # Set categories
            for cat_id in app_data.get('categories', []):
                try:
                    app.categories.add(Category.objects.get(id=cat_id))
                except:
                    pass
            
            # Update app metadata
            app.website = app_data.get('website', '') or ''
            app.user_docs = app_data.get('userDocs', '') or ''
            app.admin_docs = app_data.get('adminDocs', '') or ''
            app.developer_docs = app_data.get('developerDocs', '') or ''
            app.issue_tracker = app_data.get('issueTracker', '') or ''
            app.save()
            
            # Add translations from API
            translations = app_data.get('translations', {})
            if 'en' in translations and not app.translations.filter(language_code='en').exists():
                en = translations['en']
                app.set_current_language('en')
                app.name = en.get('name', app_id)
                app.summary = en.get('summary', '')
                app.description = en.get('description', '')
                app.save()
                translations_added += 1
            
            # Add screenshots
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
            
            # Add releases
            for rel in app_data.get('releases', []):
                ver = rel.get('version')
                if ver and not AppRelease.objects.filter(app=app, version=ver).exists():
                    platform_spec = rel.get('platformVersionSpec', '*')
                    if ' ' in platform_spec and ',' not in platform_spec:
                        platform_spec = platform_spec.replace(' ', ',')
                    php_spec = rel.get('phpVersionSpec', '*')
                    if ' ' in php_spec and ',' not in php_spec:
                        php_spec = php_spec.replace(' ', ',')
                    AppRelease.objects.create(
                        app=app,
                        version=ver,
                        platform_version_spec=platform_spec,
                        php_version_spec=php_spec,
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
EOF
fi

echo ""
echo "Done! You can now export the database with: ./scripts/db/export-db.sh"
