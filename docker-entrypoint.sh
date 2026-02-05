#!/usr/bin/env bash
# =============================================================================
# Nextcloud App Store - Docker Entrypoint
# =============================================================================
set -e

cd /srv/appstore

echo "=============================================="
echo "Nextcloud App Store - Starting Up"
echo "=============================================="

# Wait for database to be ready
if [ -n "$DATABASE_HOST" ]; then
    echo "Waiting for PostgreSQL at ${DATABASE_HOST}:${DATABASE_PORT:-5432}..."
    until pg_isready -h "$DATABASE_HOST" -p "${DATABASE_PORT:-5432}" -U "${DATABASE_USER:-nextcloudappstore}" -q; do
        echo "PostgreSQL is unavailable - sleeping 2s..."
        sleep 2
    done
    echo "PostgreSQL is ready!"
fi

# Run database migrations
echo "Running Django migrations..."
python manage.py migrate --noinput

# Collect static files
echo "Collecting static files..."
python manage.py collectstatic --noinput

# Load initial fixtures on first run (check if categories exist)
if [ "${LOAD_FIXTURES:-false}" = "true" ]; then
    echo "Loading initial data fixtures..."
    python manage.py loaddata nextcloudappstore/core/fixtures/*.json || true
fi

# Import translations
if [ "${IMPORT_TRANSLATIONS:-false}" = "true" ]; then
    echo "Importing database translations..."
    python manage.py importdbtranslations || true
fi

# Create superuser if environment variables are set
if [ -n "$DJANGO_SUPERUSER_USERNAME" ] && [ -n "$DJANGO_SUPERUSER_EMAIL" ] && [ -n "$DJANGO_SUPERUSER_PASSWORD" ]; then
    echo "Creating superuser if not exists..."
    python manage.py createsuperuser --noinput --username "$DJANGO_SUPERUSER_USERNAME" --email "$DJANGO_SUPERUSER_EMAIL" 2>/dev/null || true
    python manage.py verifyemail --username "$DJANGO_SUPERUSER_USERNAME" --email "$DJANGO_SUPERUSER_EMAIL" 2>/dev/null || true
fi

# Setup social login if configured
if [ -n "$GITHUB_CLIENT_ID" ] && [ -n "$GITHUB_CLIENT_SECRET" ] && [ -n "$SITE_DOMAIN" ]; then
    echo "Configuring GitHub social login..."
    python manage.py setupsocial --github-client-id "$GITHUB_CLIENT_ID" --github-secret "$GITHUB_CLIENT_SECRET" --domain "$SITE_DOMAIN" 2>/dev/null || true
fi

echo "=============================================="
echo "Starting application server..."
echo "=============================================="
exec "$@"
