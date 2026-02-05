# =============================================================================
# Nextcloud App Store - Production Docker Image
# =============================================================================
# Multi-stage build for optimized production deployment
# Designed for air-gapped Kubernetes deployment behind Nginx with SSL
# =============================================================================

FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Install build dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        locales \
        python3 python3-venv python3-pip python3-dev \
        build-essential \
        git \
        libpq-dev \
        gettext \
        curl \
        ca-certificates \
        libpcre3 libpcre3-dev \
    && locale-gen en_US.UTF-8 \
    && curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone the appstore repository
ARG APPSTORE_VERSION=master
RUN git clone --depth 1 --branch ${APPSTORE_VERSION} \
    https://github.com/nextcloud/appstore.git /build/appstore

WORKDIR /build/appstore

# Setup Python virtual environment
RUN python3 -m venv /build/venv
ENV VIRTUAL_ENV=/build/venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

# Install Python dependencies
RUN pip install --upgrade pip wheel && \
    pip install "poetry==1.8.2" && \
    poetry config virtualenvs.create false && \
    poetry install --no-root

# Build frontend assets
RUN npm ci && npm run build

# Compile translations
RUN python manage.py compilemessages || true

# Install uWSGI
RUN pip install uwsgi

# =============================================================================
# Production Runtime Image
# =============================================================================
FROM ubuntu:22.04 AS production

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    DJANGO_SETTINGS_MODULE=config.production

# Install runtime dependencies only
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        locales \
        python3 \
        libpq5 \
        libpcre3 \
        gettext \
        ca-certificates \
        postgresql-client \
    && locale-gen en_US.UTF-8 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create app user
RUN useradd -m -d /srv -s /bin/bash nextcloudappstore

# Copy virtual environment from builder
COPY --from=builder /build/venv /srv/venv

# Copy application from builder
COPY --from=builder /build/appstore /srv/appstore

# Set environment
ENV VIRTUAL_ENV=/srv/venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

WORKDIR /srv/appstore

# Create required directories
RUN mkdir -p /srv/static /srv/media /srv/logs /srv/config && \
    touch /srv/logs/appstore.log && \
    chown -R nextcloudappstore:nextcloudappstore /srv

# Copy entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/', timeout=5)" || exit 1

USER nextcloudappstore

EXPOSE 8000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["uwsgi", "--ini", "/srv/config/uwsgi.ini"]
