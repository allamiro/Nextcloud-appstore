FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# OS dependencies + Node.js 18.x (as in the docs)
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
    && locale-gen en_US.UTF-8 && \
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# App user + base dir
RUN useradd -m -d /srv -s /bin/bash nextcloudappstore
WORKDIR /srv

# Clone the appstore repo (adjust APPSTORE_VERSION if you want a tag)
ARG APPSTORE_VERSION=master
RUN git clone --depth 1 --branch ${APPSTORE_VERSION} \
      https://github.com/nextcloud/appstore.git /srv/appstore

# Python venv
RUN python3 -m venv /srv/venv
ENV VIRTUAL_ENV=/srv/venv
ENV PATH="${VIRTUAL_ENV}/bin:${PATH}"

# Poetry + Python deps (Poetry 1.8.2 per docs)
RUN pip install --upgrade pip wheel && \
    pip install "poetry==1.8.2"

WORKDIR /srv/appstore

# Install Python dependencies into the venv (no extra nested venvs)
RUN poetry config virtualenvs.create false && \
    poetry install --no-root

# Build frontend (npm ci / npm run build)
RUN npm ci && \
    npm run build

# Runtime directories (will usually be bound as volumes)
RUN mkdir -p /srv/static /srv/media /srv/logs /srv/config && \
    chown -R nextcloudappstore:nextcloudappstore /srv

# uWSGI (used as app server in the official Docker-based deployment)
RUN pip install uwsgi

# Copy entrypoint
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER nextcloudappstore

# For Docker-based deployment the config module is typically config.production
ENV DJANGO_SETTINGS_MODULE=config.production

EXPOSE 8000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["uwsgi", "--ini", "/srv/config/uwsgi.ini"]
