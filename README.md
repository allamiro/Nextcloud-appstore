# Nextcloud App Store - Air-Gapped Kubernetes Deployment

Complete deployment package for building the Nextcloud App Store on a staging system and deploying to a disconnected Kubernetes environment with Nginx SSL proxy.

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                  COMMERCIAL (Internet-Connected) — Docker Compose            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────┐  ┌──────────┐  ┌────────────┐  ┌────────────┐               │
│  │  Nginx   │  │App Store │  │ PostgreSQL │  │  Nextcloud │               │
│  │  :443    │─▶│  :8000   │─▶│  (AS DB)  │  │   :8083    │               │
│  │  :80     │  │ (uWSGI)  │  └────────────┘  └─────┬──────┘               │
│  └──────────┘  └──────────┘                        │ uses                 │
│                                                     ▼                      │
│  ┌──────────┐  ┌──────────┐  ┌────────────┐  ┌────────────┐               │
│  │FileServer│  │  RustFS  │  │ PostgreSQL │  │  Nextcloud │               │
│  │  :8082   │  │:9000(S3) │  │  (NC DB)  │  │  Config    │               │
│  │  :8444   │  │:9001(UI) │  └────────────┘  │  via occ   │               │
│  └──────────┘  └──────────┘                  └────────────┘               │
│                                                                              │
│  Workflow: sync → allowlist → mirror → export bundle → upload to RustFS     │
└──────────────────────────┬──────────────────────────────────────────────────┘
                           │  Transfer: images + DB dump + app archives
                           ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│          AIR-GAPPED (Offline) — Docker Compose or Kubernetes                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────┐  ┌──────────┐  ┌────────────┐  ┌────────────┐               │
│  │  Nginx   │  │App Store │  │ PostgreSQL │  │  Nextcloud │               │
│  │DC::443   │─▶│  :8000   │─▶│  (AS DB)  │  │ DC::8083   │               │
│  │K8s:30443 │  │ (uWSGI)  │  └────────────┘  │K8s::30082  │               │
│  └──────────┘  └──────────┘                  └─────┬──────┘               │
│                                                     │ uses                 │
│  ┌──────────┐  ┌──────────┐  ┌────────────┐        ▼                      │
│  │FileServer│  │  RustFS  │  │ PostgreSQL │  ┌────────────┐               │
│  │DC::30444 │  │:9000(S3) │  │  (NC DB)  │  │  App Store │               │
│  │K8s:30444 │  │:9001(UI) │  └────────────┘  │  API /v1   │               │
│  └──────────┘  └──────────┘                  └────────────┘               │
│                                                                              │
│  DC  = Docker Compose ports                                                  │
│  K8s = Kubernetes NodePort                                                   │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Runbooks:**
- Docker Compose (commercial + air-gapped): [RUN-DOCKER.md](RUN-DOCKER.md)
- Kubernetes (commercial + air-gapped): [RUN-K8s.md](RUN-K8s.md)

## Service Ports

Replace `{IP}` with your server's actual IP address or hostname.

### Docker Compose — Commercial (`docker-compose.yml`)

| Service | Host port(s) | URL | Notes |
|---------|-------------|-----|-------|
| App Store (HTTPS) | **443** | `https://{IP}/` | Main UI and API |
| App Store (HTTP) | 80 | `http://{IP}/` | Redirects to HTTPS |
| App Store API | **443** | `https://{IP}/api/v1/` | Nextcloud queries this |
| App Store Admin | **443** | `https://{IP}/admin/` | Django admin panel |
| File server (HTTPS) | **8444** | `https://{IP}:8444/apps/` | Mirrored app archives |
| File server (HTTP) | 8082 | `http://{IP}:8082/apps/` | Plain HTTP alternative |
| Nextcloud | **8083** | `http://{IP}:8083/` | Test Nextcloud instance |
| RustFS S3 API | 9000 | `http://{IP}:9000/` | S3-compatible endpoint |
| RustFS Console | **9001** | `http://{IP}:9001/` | Web management UI |

### Docker Compose — Air-Gapped (`airgapped/docker-compose/docker-compose.airgapped.yml`)

| Service | Host port(s) | URL | Notes |
|---------|-------------|-----|-------|
| App Store (HTTPS) | **30443** | `https://{IP}:30443/` | Main UI and API |
| App Store (HTTP) | 30080 | `http://{IP}:30080/` | Redirects to HTTPS |
| App Store API | **30443** | `https://{IP}:30443/api/v1/` | Nextcloud queries this |
| App Store Admin | **30443** | `https://{IP}:30443/admin/` | Django admin panel |
| File server (HTTPS) | **30444** | `https://{IP}:30444/apps/` | Mirrored app archives |
| File server (HTTP) | 30081 | `http://{IP}:30081/apps/` | Plain HTTP alternative |
| Nextcloud | **8081** | `http://{IP}:8081/` | Test Nextcloud instance |
| RustFS S3 API | 9000 | `http://{IP}:9000/` | S3-compatible endpoint |
| RustFS Console | **9001** | `http://{IP}:9001/` | Web management UI |

### Kubernetes — Commercial (`k8s/`) and Air-Gapped (`airgapped/k8s/`) — NodePorts

Both K8s paths use the same NodePort layout. Access via any cluster node IP.

| Service | NodePort(s) | URL | Notes |
|---------|-------------|-----|-------|
| App Store (HTTPS) | **30443** | `https://{IP}:30443/` | Main UI and API |
| App Store (HTTP) | 30080 | `http://{IP}:30080/` | Redirects to HTTPS |
| App Store API | **30443** | `https://{IP}:30443/api/v1/` | Nextcloud queries this |
| App Store Admin | **30443** | `https://{IP}:30443/admin/` | Django admin panel |
| File server (HTTPS) | **30444** | `https://{IP}:30444/apps/` | Mirrored app archives |
| File server (HTTP) | 30081 | `http://{IP}:30081/apps/` | Plain HTTP alternative |
| Nextcloud | **30082** | `http://{IP}:30082/` | Test Nextcloud instance |
| RustFS S3 API | **30900** | `http://{IP}:30900/` | S3-compatible endpoint |
| RustFS Console | **30901** | `http://{IP}:30901/` | Web management UI |

Internal services (`postgres`, `appstore` uWSGI) use ClusterIP and are not exposed outside the cluster.

## Directory Structure

```text
.
├── Dockerfile                    # Multi-stage production Docker image
├── docker-entrypoint.sh          # Container entrypoint script
├── docker-compose.yml            # Staging environment configuration
├── .env.example                  # Environment variables template
├── config/
│   ├── __init__.py              # Python package marker
│   ├── production.py            # Django production settings
│   └── uwsgi.ini                # uWSGI configuration
├── nginx/
│   ├── nginx.conf               # Nginx configuration for staging
│   └── ssl/                     # SSL certificates directory
├── fileserver/
│   └── nginx.conf               # File server nginx config
├── k8s/
│   ├── 01-namespace.yaml        # Kubernetes namespace
│   ├── 02-secrets.yaml          # Secrets (passwords, tokens)
│   ├── 03-configmap.yaml        # ConfigMaps (settings)
│   ├── 04-pvc.yaml              # Persistent Volume Claims
│   ├── 05-postgres.yaml         # PostgreSQL deployment + service
│   ├── 06-appstore.yaml         # App Store deployment + service
│   ├── 07-nginx.yaml            # Nginx deployment + service
│   ├── 08-cronjob.yaml          # CronJobs for maintenance
│   ├── 09-tls-secret.yaml       # TLS certificates (generated)
│   ├── 10-fileserver.yaml       # File server for app archives
│   ├── generate-certs.sh        # SSL certificate generator
│   └── certs/                   # Generated certificates
├── scripts/
│   ├── build-and-export.sh      # Build and export for air-gap transfer
│   ├── sync-apps.sh             # Sync apps from official store
│   ├── db/
│   │   ├── export-db.sh         # Export PostgreSQL database
│   │   └── import-db.sh         # Import PostgreSQL database
│   └── mirror-apps/
│       ├── 01-extract-urls.sh   # Extract download URLs
│       ├── 02-download-apps.sh  # Download app archives
│       └── 03-update-db-urls.sh # Update URLs to local server
└── exports/                     # Generated export files (gitignored)
    ├── *.tar.gz                 # Docker images
    ├── appstore_db_*.sql.gz     # Database dumps
    └── app-archives/            # Downloaded app files
```

---

## Part 1: Staging System Setup (Internet Connected)

### Prerequisites

- Ubuntu 22.04 or similar Linux distribution
- Docker and Docker Compose installed
- Git installed
- Minimum 4GB RAM, 20GB disk space
- GitHub account (for API token and optional OAuth)

### Step 0: Configure GitHub Credentials (Before Creating .env)

Before setting up the App Store, you need to create GitHub credentials. There are **two types** required:

#### A. GitHub Personal Access Token (Required)

This token is **required** for syncing Nextcloud releases from GitHub.

1. Go to **https://github.com/settings/tokens**
2. Click **"Generate new token (classic)"**
3. Configure the token:

| Field | Value |
|-------|-------|
| **Note** | `nextcloud-appstore-sync` |
| **Expiration** | Select duration (recommend 90 days or "No expiration" for production) |

4. Select these **scopes** (minimum required):

| Scope | Description |
|-------|-------------|
| ☑️ `public_repo` | Access public repositories (under `repo`) |

5. Click **"Generate token"**
6. **Copy the token immediately** (starts with `ghp_...`) - you won't see it again!
7. You will needs this for the .env file. Make sure its saved.Save this as `GITHUB_API_TOKEN` in your `.env` file

#### B. GitHub OAuth App (Optional - For Social Login)

This allows users to log in to the App Store using their GitHub account.

1. Go to **https://github.com/settings/developers**
2. Click **"New OAuth App"**
3. Fill in the registration form:

| Field | Example Value |
|-------|---------------|
| **Application name** | `Nextcloud App Store` |
| **Homepage URL** | `https://appstore.example.com` |
| **Application description** | `Nextcloud App Store - Browse and download apps for Nextcloud` |
| **Authorization callback URL** | `https://appstore.example.com/github/login/callback/` |

4. Click **"Register application"**
5. On the next page, you'll see your **Client ID**
6. Click **"Generate a new client secret"**
7. **Copy both values immediately:**
   - `GITHUB_CLIENT_ID` → Client ID
   - `GITHUB_CLIENT_SECRET` → Client Secret (shown only once!)

> **Note:** For local development/staging, use:
> - Homepage URL: `https://localhost`
> - Callback URL: `https://localhost/github/login/callback/`

---

### Step 1: Clone and Configure

```bash
# Clone this repository
git clone https://github.com/allamiro/Nextcloud-appstore.git
cd Nextcloud-appstore

# Copy environment template
cp .env.example .env

# Edit configuration
nano .env
```

**Important `.env` settings to configure:**

```bash
# Generate a secure secret key (IMPORTANT: avoid $ characters)
env LC_CTYPE=C tr -dc "a-zA-Z0-9_-" < /dev/urandom | head -c 64; echo
# Copy the output and set it as SECRET_KEY in .env

# Set your database password
DB_PASSWORD=your_secure_password_here

# Set your domain
ALLOWED_HOSTS=localhost,127.0.0.1,appstore.example.com
SITE_DOMAIN=appstore.example.com

# GitHub API token (required for syncing releases)
# Get from: https://github.com/settings/tokens
GITHUB_API_TOKEN=ghp_your_github_token_here

# Admin credentials (created automatically on first run)
ADMIN_USERNAME=admin
ADMIN_EMAIL=admin@example.com
ADMIN_PASSWORD=your_secure_admin_password
```

> **⚠️ Important:** Do not use `$` characters in `SECRET_KEY` or passwords — Docker Compose interprets them as variable substitution.

### Step 2: Generate TLS Certificates

The stack uses a 3-tier CA chain (Root CA → Intermediate CA → Server cert). Generate
all certificates with the provided script. Set `SERVER_CN` to the IP address or hostname
that Nextcloud will use to reach the App Store.

```bash
# Replace with your host's LAN IP or a DNS name
SERVER_CN=192.168.1.100 bash k8s/generate-certs.sh
```

This creates `k8s/certs/server.crt`, `k8s/certs/server.key`, and `k8s/certs/root-ca.crt`,
and copies the cert chain into `nginx/ssl/` automatically.

To trust the root CA on your workstation (so your browser accepts the App Store):
```bash
# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \
    k8s/certs/root-ca.crt

# Linux (Debian/Ubuntu)
sudo cp k8s/certs/root-ca.crt /usr/local/share/ca-certificates/appstore-root-ca.crt \
    && sudo update-ca-certificates
```

### Step 3: Start the Full Stack

Use `appstorectl.sh` — it handles macOS Docker Desktop bind-mount restrictions
automatically by staging configs to `~/.appstore-runtime/` before starting containers.

```bash
# Builds the App Store image and starts all services
./scripts/appstorectl.sh online up

# View startup logs (wait for "Starting application server...")
docker compose logs -f appstore
```

### Step 4: Connect Nextcloud to the App Store

Wait ~60 seconds for Nextcloud to finish its first-boot installation, then:

```bash
./scripts/appstorectl.sh online setup-nextcloud
```

The admin user is created automatically using credentials from `.env`:
- `ADMIN_USERNAME`
- `ADMIN_EMAIL`  
- `ADMIN_PASSWORD`

### Step 5: Sync App Metadata (Requires Internet)

This step is handled automatically by `appstorectl.sh online sync` — it runs both
the app metadata sync and the Nextcloud releases sync in one command:

```bash
./scripts/appstorectl.sh online sync
```

To sync a limited set for testing:
```bash
./scripts/appstorectl.sh online sync --limit 10
```

**What gets imported:**
- App metadata (name, summary, description, categories)
- All release versions with download URLs, signatures, and platform specs
- English translations and screenshots
- Nextcloud server releases (NC version → channel mapping for the releases grid)

**Expected output:**
```
Sync complete!
New apps imported: 312
Translations added: 312
Screenshots added: 1847
Total apps: 312
Total releases: 4821
[OK] Nextcloud releases synced.
```

> To change which platform versions are fetched, set
> `APPSTORE_SYNC_PLATFORMS=30.0.0,31.0.0,33.0.0` in `.env` before running sync.

### Step 6: Configure GitHub Social Login (Optional)

If you provided `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` in `.env`, GitHub login is configured automatically.

To configure manually or update:

```bash
docker compose exec appstore python manage.py setupsocial \
    --github-client-id "YOUR_CLIENT_ID" \
    --github-secret "YOUR_CLIENT_SECRET" \
    --domain appstore.example.com
```

### Step 7: Verify Staging Environment

```bash
# Check container status
docker compose ps

# View logs
docker compose logs appstore
```

**Access URLs:**

| URL | Description |
|-----|-------------|
| `https://localhost` | App Store (accept self-signed cert) |
| `https://localhost/admin/` | Admin Panel |

**Expected result:** The App Store homepage loads with:

- Categories in the sidebar
- Apps listed with names, descriptions, and screenshots
- Clicking an app shows its detail page with download links

---

## Part 2: Export for Air-Gapped Transfer

> **⚠️ Important Air-Gap Considerations:**
>
> - App download URLs point to external sources (GitHub, etc.) which won't work offline
> - Screenshots are hosted on GitHub and won't load without internet
> - For true air-gapped use, you may need to mirror app archives locally
> - The database export includes all app metadata for browsing/searching

### Step 1: Export Docker Images

```bash
# Make scripts executable
chmod +x scripts/*.sh scripts/db/*.sh

# Build and export all images
./scripts/build-and-export.sh
```

This creates in `exports/`:

- `nextcloudappstore_latest_TIMESTAMP.tar.gz` - App Store image
- `postgres_15-alpine_TIMESTAMP.tar.gz` - PostgreSQL image
- `nginx_alpine_TIMESTAMP.tar.gz` - Nginx image
- SHA256 checksums for verification

### Step 2: Export Database

```bash
# Export database (runs pg_dump inside the postgres container)
./scripts/db/export-db.sh
```

This creates:

- `exports/appstore_db_TIMESTAMP.sql.gz` - Complete database dump (~5-10MB)
- `exports/appstore_db_TIMESTAMP.sql.gz.sha256` - Checksum

**The database includes:**

- All 566 apps with metadata
- 14,000+ release versions
- 661 screenshot URLs
- Categories and translations
- Admin user account

### Step 3: Download App Archives (For Full Air-Gap)

**This step is required if you want Nextcloud to actually install apps** (not just browse them).

```bash
# Make mirror scripts executable
chmod +x scripts/mirror-apps/*.sh

# Extract all download URLs from database
sh scripts/mirror-apps/01-extract-urls.sh

# Download all app archives (~13,000+ files, several GB)
# This takes a while - you can cancel and resume later
sh scripts/mirror-apps/02-download-apps.sh

# Update database URLs to point to local file server
FILE_SERVER_URL=https://localhost:30444/apps sh scripts/mirror-apps/03-update-db-urls.sh

# Re-export database with updated URLs
sh scripts/db/export-db.sh
```

This creates in `exports/app-archives/`:

- `urls.txt` - List of all download URLs
- `files/` - Downloaded .tar.gz app archives
- `failed.txt` - Any URLs that failed to download

### Step 4: Prepare Transfer Package

```bash
# View what will be transferred
ls -la exports/

# Create a single archive for transfer (includes app archives)
tar -cvf appstore-deployment-package.tar \
    exports/ k8s/ config/ nginx/ fileserver/ scripts/

# Check size (may be several GB with app archives)
ls -lh appstore-deployment-package.tar
```

### Step 5: Transfer to Disconnected Environment

Transfer `appstore-deployment-package.tar` to your disconnected server using:

- USB drive
- Secure file transfer
- Air-gapped network bridge

---

## Part 3: Kubernetes Deployment (Air-Gapped)

### Prerequisites

- Kubernetes cluster (Docker Desktop, Tanzu, or any K8s 1.24+)
- kubectl configured
- Docker installed (for loading images)

### Kubernetes Manifest Files

Files are numbered in deployment order:

```text
k8s/
├── 01-namespace.yaml      # Namespace
├── 02-secrets.yaml        # App and DB secrets
├── 03-configmap.yaml      # Django, uWSGI config
├── 04-pvc.yaml            # Persistent volumes
├── 05-postgres.yaml       # PostgreSQL deployment + service
├── 06-appstore.yaml       # App Store deployment + service
├── 07-nginx.yaml          # Nginx with SSL + NodePort service
├── 08-cronjob.yaml        # Optional scheduled tasks
├── 09-tls-secret.yaml     # TLS certificates (generated)
├── 10-fileserver.yaml     # File server for app archives
├── generate-certs.sh      # Script to generate SSL certs
└── certs/                 # Generated certificate files
```

### Step 1: Extract Transfer Package

```bash
tar -xvf appstore-deployment-package.tar
```

### Step 2: Load Docker Images

```bash
cd exports
for file in *.tar.gz; do
    echo "Loading ${file}..."
    gunzip -c "${file}" | docker load
done

# Verify images
docker images | grep -E "(nextcloudappstore|postgres|nginx)"
cd ..
```

### Step 3: Generate SSL Certificates

```bash
# Generate CA chain and server certificates
sh k8s/generate-certs.sh

# This creates:
# - k8s/certs/           (certificate files)
# - k8s/09-tls-secret.yaml (K8s secret with certs)
```

### Step 4: Deploy to Kubernetes

```bash
# Apply manifests in order:
kubectl apply -f k8s/01-namespace.yaml
kubectl apply -f k8s/02-secrets.yaml
kubectl apply -f k8s/03-configmap.yaml
kubectl apply -f k8s/04-pvc.yaml
kubectl apply -f k8s/05-postgres.yaml

# Wait for PostgreSQL to be ready
sleep 15
kubectl get pods -n nextcloud-appstore

# Deploy app, TLS secret, and nginx
kubectl apply -f k8s/06-appstore.yaml
kubectl apply -f k8s/09-tls-secret.yaml
kubectl apply -f k8s/07-nginx.yaml

# Wait for all pods
sleep 30
kubectl get pods -n nextcloud-appstore
```

### Step 5: Import Database

```bash
# Import the database
DB_DUMP=$(ls exports/appstore_db_*.sql.gz | sort -r | head -1)
sh scripts/db/import-db.sh "${DB_DUMP}" k8s
```

### Step 6: Create Admin Account

```bash
# Create a superuser for admin access
kubectl exec -it deployment/appstore -n nextcloud-appstore -- \
    python manage.py createsuperuser
```

Follow the prompts to enter username, email, and password.

### Step 7: Verify Deployment

```bash
# Check all pods are running
kubectl get pods -n nextcloud-appstore

# Check services
kubectl get svc -n nextcloud-appstore

# View application logs
kubectl logs -f deployment/appstore -n nextcloud-appstore

# Test health endpoint
curl -k https://localhost:30443/health/
```

### Step 8: Access the Application

| URL | Description |
|-----|-------------|
| https://localhost:30443 | App Store (HTTPS) |
| https://localhost:30443/admin/ | Django Admin Panel |
| https://localhost:30444/apps/ | File Server (App Archives) |
| http://localhost:30080 | HTTP (redirects to HTTPS) |

**Note:** You'll see a browser SSL warning (self-signed cert). Click "Advanced" → "Proceed" to continue.

**Optional - Trust the CA on macOS:**

```bash
sudo security add-trusted-cert -d -r trustRoot \
    -k /Library/Keychains/System.keychain \
    k8s/certs/root-ca.crt
```

### Step 9: Run Initial Setup Job (if not importing database)

```bash
# Only if starting fresh without database import
kubectl apply -f k8s/08-cronjob.yaml

# Trigger the initial setup job
kubectl create job --from=cronjob/appstore-initial-setup \
    initial-setup-manual -n nextcloud-appstore
```

---

## Maintenance

### Scripts Reference

All available scripts and their purposes:

| Script | Purpose | Environment |
|--------|---------|-------------|
| `scripts/sync-apps.sh` | Sync apps from official Nextcloud App Store | Staging (online) |
| `scripts/build-and-export.sh` | Build Docker images and export for transfer | Staging (online) |
| `scripts/create-admin.sh` | Create admin user account | Both |
| `scripts/import-and-deploy.sh` | Full import and deploy automation | Air-gapped K8s |
| `scripts/db/export-db.sh` | Export PostgreSQL database | Staging |
| `scripts/db/import-db.sh` | Import PostgreSQL database | Air-gapped K8s |
| `scripts/mirror-apps/01-extract-urls.sh` | Extract all app download URLs from DB | Staging (online) |
| `scripts/mirror-apps/02-download-apps.sh` | Download all .tar.gz app archives | Staging (online) |
| `scripts/mirror-apps/03-update-db-urls.sh` | Update DB URLs to local file server | Staging |

### Repeatable Update Cycle

When apps need updating, follow this repeatable process:

**On Staging (internet-connected):**

```bash
# Re-sync apps from official Nextcloud App Store
sh scripts/sync-apps.sh

# (Optional) Download new app archives for file server
sh scripts/mirror-apps/01-extract-urls.sh
sh scripts/mirror-apps/02-download-apps.sh

# Re-export database with updated apps
sh scripts/db/export-db.sh

# Package for transfer
tar -cvf appstore-update.tar exports/appstore_db_*.sql.gz exports/app-archives/
```

**On Air-Gapped Kubernetes:**

```bash
# Extract and import updated database
tar -xvf appstore-update.tar
sh scripts/db/import-db.sh exports/appstore_db_*.sql.gz k8s

# Update file server with new app archives
FS_POD=$(kubectl get pod -l app=fileserver -n nextcloud-appstore -o jsonpath='{.items[0].metadata.name}')
kubectl cp exports/app-archives/files/. nextcloud-appstore/${FS_POD}:/srv/apps/

# Verify apps are updated
kubectl logs -f deployment/appstore -n nextcloud-appstore
```

### Updating the Application Code

**On Staging (internet-connected):**

```bash
# Update repository
git pull origin main

# Rebuild image with new version
docker compose build appstore

# Re-export images and transfer to production
sh scripts/build-and-export.sh
```

**On Air-Gapped Kubernetes:**

```bash
# Load new image
gunzip -c exports/nextcloudappstore_*.tar.gz | docker load

# Rolling update
kubectl rollout restart deployment/appstore -n nextcloud-appstore
kubectl rollout status deployment/appstore -n nextcloud-appstore
```

### Database Backup

```bash
# On Kubernetes
PG_POD=$(kubectl get pod -l app=postgres -n nextcloud-appstore \
    -o jsonpath='{.items[0].metadata.name}')

kubectl exec "${PG_POD}" -n nextcloud-appstore -- \
    pg_dump -U nextcloudappstore nextcloudappstore | gzip > backup.sql.gz
```

### Scaling

```bash
# Scale App Store replicas
kubectl scale deployment/appstore --replicas=4 -n nextcloud-appstore

# Scale Nginx replicas
kubectl scale deployment/nginx --replicas=4 -n nextcloud-appstore
```

### Troubleshooting

```bash
# Check pod status
kubectl describe pod -l app=appstore -n nextcloud-appstore

# Check logs
kubectl logs -f deployment/appstore -n nextcloud-appstore
kubectl logs -f deployment/nginx -n nextcloud-appstore
kubectl logs -f deployment/postgres -n nextcloud-appstore

# Access shell in container
kubectl exec -it deployment/appstore -n nextcloud-appstore -- /bin/bash

# Run Django management commands
kubectl exec -it deployment/appstore -n nextcloud-appstore -- \
    python manage.py shell
```

---

## Air-Gapped Environment Notes

**User Management:**

- GitHub OAuth is **disabled** (no internet access)
- Users must be created via Django admin panel at `/admin/`
- Admin credentials are set via environment variables or during initial setup

**To create additional users:**

```bash
# Access the appstore pod
kubectl exec -it deployment/appstore -n nextcloud-appstore -- /bin/bash

# Create a superuser
python manage.py createsuperuser
```

---

## Full Air-Gap Setup (App Downloads)

For Nextcloud to actually **download and install** apps, you need a local file server hosting the app archives.

### Step 1: Download App Archives (While Online)

```bash
# Extract all download URLs from database
sh scripts/mirror-apps/01-extract-urls.sh

# Download all app archives (~13,000+ files, several GB)
sh scripts/mirror-apps/02-download-apps.sh

# Update database URLs to point to local file server
FILE_SERVER_URL=https://localhost:30444/apps sh scripts/mirror-apps/03-update-db-urls.sh

# Re-export database with updated URLs
sh scripts/db/export-db.sh
```

### Step 2: Deploy File Server (In Air-Gap)

```bash
# Deploy the file server
kubectl apply -f k8s/10-fileserver.yaml

# Wait for it to be ready
kubectl wait --for=condition=ready pod -l app=fileserver \
    -n nextcloud-appstore --timeout=60s
```

### Step 3: Copy App Archives to File Server

```bash
# Get the fileserver pod name
FS_POD=$(kubectl get pod -l app=fileserver -n nextcloud-appstore \
    -o jsonpath='{.items[0].metadata.name}')

# Copy all app archives to the file server
kubectl cp exports/app-archives/files/. \
    nextcloud-appstore/${FS_POD}:/srv/apps/
```

### Step 4: Verify File Server

```bash
# Check files are accessible
curl -k https://localhost:30444/apps/

# Should list all .tar.gz files
```

---

## Nextcloud Integration

Configure your air-gapped Nextcloud server to use this App Store.

**Step 1:** On Nextcloud Server, edit `config/config.php`:

```php
'appstoreurl' => 'https://appstore.local:30443/api/v1',
```

**Step 2:** Add your CA certificate to Nextcloud's trust store:

```bash
# Copy CA cert to Nextcloud container
cp k8s/certs/root-ca.crt /path/to/nextcloud/data/

# In Nextcloud config.php, add to trusted CAs
'appstoreenabled' => true,
'appstore.experimental.enabled' => true,
```

**Step 3:** Configure DNS or `/etc/hosts` on Nextcloud server:

```bash
# Add entries for both App Store and File Server
echo "10.97.10.197 appstore.local files.local" >> /etc/hosts
```

To get your service IPs:

```bash
kubectl get svc -n nextcloud-appstore
```

---

## Security Notes

1. **Always change default passwords** in `k8s/02-secrets.yaml`
2. **Generate a unique SECRET_KEY** for production
3. **Use proper TLS certificates** signed by your custom CA
4. **Restrict network policies** in Kubernetes
5. **Regular backups** of PostgreSQL data
6. **Keep images updated** with security patches

---

## License

This deployment package is provided under the same license as the Nextcloud App Store (AGPL-3.0).
