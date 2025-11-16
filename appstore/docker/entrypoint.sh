#!/usr/bin/env bash
set -e

# Optional: wait for Postgres to be ready
if [ -n "$POSTGRES_HOST" ]; then
  echo "Waiting for Postgres at ${POSTGRES_HOST}:${POSTGRES_PORT:-5432}..."
  until nc -z "$POSTGRES_HOST" "${POSTGRES_PORT:-5432}"; do
    sleep 1
  done
fi

echo "Applying database migrations..."
python manage.py migrate --noinput

# Optional: load fixtures once in a fresh environment
if [ "${LOAD_INITIAL_DATA}" = "1" ]; then
  echo "Loading initial data..."
  python manage.py loaddata nextcloudappstore/core/fixtures/*.json || true
fi

echo "Collecting static files..."
python manage.py collectstatic --noinput

# Optional: compile messages/import translations on container start
if [ "${COMPILE_MESSAGES}" = "1" ]; then
  echo "Compiling and importing translations..."
  python manage.py compilemessages || true
  python manage.py importdbtranslations || true
fi

# Logging file location
touch /app/appstore.log
chmod 664 /app/appstore.log

echo "Starting gunicorn..."
exec gunicorn nextcloudappstore.wsgi:application \
  --bind 0.0.0.0:8000 \
  --workers "${GUNICORN_WORKERS:-4}" \
  --timeout "${GUNICORN_TIMEOUT:-120}"
