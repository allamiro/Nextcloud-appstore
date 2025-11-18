#!/usr/bin/env bash
set -e

# Simple entrypoint: run migrations & collectstatic, then start uWSGI
cd /srv/appstore

echo "Running Django migrations..."
python manage.py migrate --noinput

echo "Collecting static files..."
python manage.py collectstatic --noinput

# You can uncomment this on first run if you want fixtures:
# echo "Loading initial data fixtures..."
# python manage.py loaddata nextcloudappstore/core/fixtures/*.json

echo "Starting application server..."
exec "$@"
