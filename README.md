# Nextcloud App Store - Air-Gapped Kubernetes Deployment

Complete deployment package for building the Nextcloud App Store on a staging system and deploying to a disconnected Kubernetes environment with Nginx SSL proxy.

## Architecture Overview

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                        STAGING SYSTEM (Internet Connected)                   │
├─────────────────────────────────────────────────────────────────────────────┤
│  1. Build Docker image                                                       │
│  2. Run staging environment with docker-compose                              │
│  3. Populate database (admin user, fixtures, sync releases)                  │
│  4. Download app archives (for full air-gap)                                 │
│  5. Export Docker images + PostgreSQL dump                                   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼ Transfer exports/
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PRODUCTION (Disconnected Kubernetes)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐  │
│  │   Nginx     │───▶│  App Store  │───▶│  PostgreSQL │    │ File Server │  │
│  │  :30443     │    │   (uWSGI)   │    │  (Database) │    │   :30444    │  │
│  │  NodePort   │    └─────────────┘    └─────────────┘    │ App Archives│  │
│  └─────────────┘           │                              └─────────────┘  │
│         │                  │                                     │          │
│         │                  ▼                                     │          │
│         │           ┌─────────────┐    ┌─────────────┐          │          │
│         │           │   Static    │    │    Media    │          │          │
│         │           │    PVC      │    │     PVC     │          │          │
│         │           └─────────────┘    └─────────────┘          │          │
│         │                                                        │          │
│         └────────────────────┬───────────────────────────────────┘          │
│                              ▼                                              │
│                       ┌─────────────┐                                       │
│                       │  Nextcloud  │  ← Queries API + Downloads Apps       │
│                       │   Server    │                                       │
│                       └─────────────┘                                       │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Service Ports

### Docker Compose (Staging)

| Service | Port | URL | Purpose |
|---------|------|-----|---------|
| PostgreSQL | 5432 | localhost:5432 | Database |
| App Store | 8000 | http://localhost:8000 | Django API/UI |
| Nginx Proxy | 80/443 | https://localhost | SSL Proxy |
| File Server | 8080/8443 | http://localhost:8080/apps/ | App Archives |

### Kubernetes (Air-Gapped)

| Service | Port | NodePort | URL | Purpose |
|---------|------|----------|-----|---------|
| postgres-service | 5432 | - | ClusterIP | Database |
| appstore-service | 8000 | - | ClusterIP | Django Backend |
| nginx-service | 80/443 | 30080/30443 | https://localhost:30443 | App Store UI/API |
| fileserver-service | 80/443 | 30081/30444 | https://localhost:30444/apps/ | App Archives |

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

> **⚠️ Important:** Do not use `$` characters in `SECRET_KEY` or passwords as docker-compose interprets them as variables.

### Step 2: Generate SSL Certificates (for staging)

```bash
# Create self-signed certificates for staging
mkdir -p nginx/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout nginx/ssl/server.key \
    -out nginx/ssl/server.crt \
    -subj "/CN=appstore.example.com"
```

### Step 3: Build the Docker Image

```bash
# Build the App Store image
docker-compose build appstore

# Verify the image was created
docker images | grep nextcloudappstore
```

### Step 4: Start the Staging Environment

```bash
# Start the full stack with initial setup flags
# This will:
#   - Create database and run migrations
#   - Load initial fixtures (categories, etc.)
#   - Import translations
#   - Create admin user (from .env credentials)
#   - Configure GitHub OAuth (if credentials provided)
LOAD_FIXTURES=true IMPORT_TRANSLATIONS=true docker-compose up -d

# View startup logs (wait for "Starting application server...")
docker-compose logs -f appstore
```

The admin user is created automatically using credentials from `.env`:
- `ADMIN_USERNAME`
- `ADMIN_EMAIL`  
- `ADMIN_PASSWORD`

### Step 5: Sync Nextcloud Releases (Requires Internet)

```bash
# Preview releases that will be synced
docker-compose exec appstore python manage.py syncnextcloudreleases \
    --oldest-supported="25.0.0" --print

# Sync releases from GitHub (requires GITHUB_API_TOKEN in .env)
docker-compose exec appstore python manage.py syncnextcloudreleases \
    --oldest-supported="25.0.0"
```

This syncs Nextcloud server releases (v25.0.0 to latest), which apps use to declare compatibility.

### Step 6: Import Apps from Official App Store (Requires Internet)

**This is the key step for air-gapped deployment** - it imports all apps from the official Nextcloud App Store into your local instance.

```bash
# Test with a small batch first
./scripts/sync-apps.sh --limit 10

# Import ALL apps (takes several minutes)
./scripts/sync-apps.sh
```

This fetches all apps and their releases from `https://apps.nextcloud.com` and imports them into your local database.

**What gets imported:**

- App metadata (name, summary, description, categories)
- All release versions with download URLs and signatures
- Platform compatibility information
- Screenshots (images hosted on GitHub)
- Documentation links

**Expected output:**

```text
Sync complete!
New apps imported: 342
Translations added: 342
Screenshots added: 661
Total apps: 566
Total releases: 14031
```

> **Note:** The sync imports apps compatible with Nextcloud 30.x. Apps for older NC versions are also imported from the general API but may have fewer details.

### Step 7: Configure GitHub Social Login (Optional)

If you provided `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` in `.env`, GitHub login is configured automatically.

To configure manually or update:

```bash
docker-compose exec appstore python manage.py setupsocial \
    --github-client-id "YOUR_CLIENT_ID" \
    --github-secret "YOUR_CLIENT_SECRET" \
    --domain appstore.example.com
```

### Step 8: Verify Staging Environment

```bash
# Check container status
docker-compose ps

# View logs
docker-compose logs appstore
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

### Step 3: Prepare Transfer Package

```bash
# View what will be transferred
ls -la exports/

# Create a single archive for transfer
tar -cvf appstore-deployment-package.tar exports/ k8s/ config/ nginx/

# Check size
ls -lh appstore-deployment-package.tar
```

### Step 4: Transfer to Disconnected Environment

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

### Repeatable Update Cycle

When apps need updating, follow this repeatable process:

**On Staging (internet-connected):**

```bash
# Re-sync apps from official Nextcloud App Store
sh scripts/sync-apps.sh

# Re-export database with updated apps
sh scripts/db/export-db.sh

# Package for transfer
tar -cvf appstore-update.tar exports/appstore_db_*.sql.gz
```

**On Air-Gapped Kubernetes:**

```bash
# Extract and import updated database
tar -xvf appstore-update.tar
sh scripts/db/import-db.sh exports/appstore_db_*.sql.gz k8s

# Verify apps are updated
kubectl logs -f deployment/appstore -n nextcloud-appstore
```

### Updating the Application Code

**On Staging (internet-connected):**

```bash
# Update repository
git pull origin main

# Rebuild image with new version
docker-compose build appstore

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
