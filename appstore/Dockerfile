# =========================
# Stage 1: Build frontend
# =========================
FROM node:18-bullseye AS frontend

WORKDIR /app

# Only copy package files first to leverage Docker layer cache
COPY package*.json ./

RUN npm ci

# Now copy the rest of the repository and build frontend
COPY . .
RUN npm run build


# =========================
# Stage 2: Python runtime
# =========================
FROM python:3.11-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=off \
    POETRY_VIRTUALENVS_CREATE=false \
    POETRY_NO_INTERACTION=1 \
    DJANGO_SETTINGS_MODULE=nextcloudappstore.settings.production

WORKDIR /app

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gettext \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Poetry
RUN pip install --upgrade pip wheel "poetry==1.8.2"

# Install Python deps using Poetry (no dev deps)
COPY pyproject.toml poetry.lock* ./
RUN poetry install --no-dev --no-root

# Copy application source
COPY . .

# Copy built frontend assets from the Node stage (if they live under nextcloudappstore/static)
COPY --from=frontend /app/nextcloudappstore/static /app/nextcloudappstore/static

# Prepare static/media directories (these will be mounted as volumes)
RUN mkdir -p /var/www/nextcloud-appstore/static /var/www/nextcloud-appstore/media

# Entry script
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8000

CMD ["/entrypoint.sh"]
