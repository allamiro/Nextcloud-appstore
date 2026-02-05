# Nextcloud App Store - Air-Gapped Kubernetes Deployment

Complete deployment package for building the Nextcloud App Store on a staging system and deploying to a disconnected Kubernetes environment with Nginx SSL proxy.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        STAGING SYSTEM (Internet Connected)                   │
├─────────────────────────────────────────────────────────────────────────────┤
│  1. Build Docker image                                                       │
│  2. Run staging environment with docker-compose                              │
│  3. Populate database (admin user, fixtures, sync releases)                  │
│  4. Export Docker images + PostgreSQL dump                                   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼ Transfer exports/
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PRODUCTION (Disconnected Kubernetes)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐  │
│  │   Ingress   │───▶│    Nginx    │───▶│  App Store  │───▶│  PostgreSQL │  │
│  │   (SSL)     │    │   (Proxy)   │    │   (uWSGI)   │    │  (Database) │  │
│  └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘  │
│                            │                  │                             │
│                            ▼                  ▼                             │
│                     ┌─────────────┐    ┌─────────────┐                      │
│                     │   Static    │    │    Media    │                      │
│                     │    PVC      │    │     PVC     │                      │
│                     └─────────────┘    └─────────────┘                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
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
├── k8s/
│   ├── kustomization.yaml       # Kustomize configuration
│   ├── namespace.yaml           # Kubernetes namespace
│   ├── secrets.yaml             # Secrets (passwords, tokens)
│   ├── configmap.yaml           # ConfigMaps (settings)
│   ├── pvc.yaml                 # Persistent Volume Claims
│   ├── postgres-deployment.yaml # PostgreSQL deployment + service
│   ├── appstore-deployment.yaml # App Store deployment + service
│   ├── nginx-deployment.yaml    # Nginx deployment + service
│   ├── ingress.yaml             # Ingress with SSL/TLS
│   └── cronjob.yaml             # CronJobs for maintenance
├── scripts/
│   ├── build-and-export.sh      # Build and export for air-gap transfer
│   ├── import-and-deploy.sh     # Import and deploy on disconnected env
│   └── db/
│       ├── export-db.sh         # Export PostgreSQL database
│       └── import-db.sh         # Import PostgreSQL database
└── exports/                     # Generated export files (gitignored)
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
# Generate a secure secret key
SECRET_KEY=$(env LC_CTYPE=C tr -dc "a-zA-Z0-9-_\$\?" < /dev/urandom | head -c 64; echo)
echo "SECRET_KEY=${SECRET_KEY}" >> .env

# Set your database password
DB_PASSWORD=your_secure_password_here

# Set your domain
ALLOWED_HOSTS=localhost,127.0.0.1,appstore.example.com
SITE_DOMAIN=appstore.example.com

# GitHub API token (required for syncing releases)
# Get from: https://github.com/settings/tokens
GITHUB_API_TOKEN=your_github_token_here
```

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
# Start PostgreSQL first
docker-compose up -d postgres

# Wait for PostgreSQL to be ready
sleep 10

# Start the full stack with initial setup flags
LOAD_FIXTURES=true IMPORT_TRANSLATIONS=true docker-compose up -d

# View logs
docker-compose logs -f appstore
```

### Step 5: Create Admin User

```bash
# Create superuser
docker-compose exec appstore python manage.py createsuperuser \
    --username admin --email admin@example.com

# Verify email
docker-compose exec appstore python manage.py verifyemail \
    --username admin --email admin@example.com
```

### Step 6: Sync Nextcloud Releases (Requires Internet)

```bash
# Sync releases from GitHub (requires GITHUB_API_TOKEN in .env)
docker-compose exec appstore python manage.py syncnextcloudreleases \
    --oldest-supported="25.0.0"

# Verify with a test run first
docker-compose exec appstore python manage.py syncnextcloudreleases \
    --oldest-supported="25.0.0" --print
```

### Step 7: Configure GitHub Social Login (Optional)

1. Go to https://github.com/settings/developers
2. Create new OAuth App:
   - **Application name:** Nextcloud App Store
   - **Homepage URL:** https://appstore.example.com
   - **Authorization callback URL:** https://appstore.example.com/github/login/callback/

3. Configure in the app:
```bash
docker-compose exec appstore python manage.py setupsocial \
    --github-client-id "YOUR_CLIENT_ID" \
    --github-secret "YOUR_CLIENT_SECRET" \
    --domain appstore.example.com
```

### Step 8: Verify Staging Environment

```bash
# Access the app store
# HTTP:  http://localhost:8000
# HTTPS: https://localhost (self-signed cert warning expected)

# Check health
curl -k https://localhost/health/
```

---

## Part 2: Export for Air-Gapped Transfer

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
# Set database credentials
export DATABASE_HOST=localhost
export DATABASE_PORT=5432
export DATABASE_USER=nextcloudappstore
export DATABASE_PASSWORD=your_password

# Export database
./scripts/db/export-db.sh
```

This creates:
- `exports/appstore_db_TIMESTAMP.sql.gz` - Database dump
- `exports/appstore_db_TIMESTAMP.sql.gz.sha256` - Checksum

### Step 3: Prepare Transfer Package

```bash
# The exports/ directory contains everything needed
ls -la exports/

# Create a single archive for transfer
tar -cvf appstore-deployment-package.tar exports/ k8s/ config/ nginx/
```

### Step 4: Transfer to Disconnected Environment

Transfer `appstore-deployment-package.tar` to your disconnected server using:
- USB drive
- Secure file transfer
- Air-gapped network

---

## Part 3: Kubernetes Deployment (Disconnected)

### Prerequisites on Disconnected Server

- Kubernetes cluster (1.24+)
- kubectl configured
- Docker installed (for loading images)
- (Optional) Private container registry

### Step 1: Extract Transfer Package

```bash
# Extract the package
tar -xvf appstore-deployment-package.tar
cd exports
```

### Step 2: Load Docker Images

```bash
# Load images into Docker
for file in *.tar.gz; do
    echo "Loading ${file}..."
    gunzip -c "${file}" | docker load
done

# Verify images
docker images | grep -E "(nextcloudappstore|postgres|nginx)"
```

### Step 3: (Optional) Push to Private Registry

If using a private registry:

```bash
REGISTRY=your-registry.example.com:5000

# Tag images
docker tag nextcloudappstore:latest ${REGISTRY}/nextcloudappstore:latest
docker tag postgres:15-alpine ${REGISTRY}/postgres:15-alpine
docker tag nginx:alpine ${REGISTRY}/nginx:alpine

# Push images
docker push ${REGISTRY}/nextcloudappstore:latest
docker push ${REGISTRY}/postgres:15-alpine
docker push ${REGISTRY}/nginx:alpine

# Update Kubernetes manifests
sed -i "s|image: nextcloudappstore:|image: ${REGISTRY}/nextcloudappstore:|g" k8s/*.yaml
sed -i "s|image: postgres:|image: ${REGISTRY}/postgres:|g" k8s/*.yaml
sed -i "s|image: nginx:|image: ${REGISTRY}/nginx:|g" k8s/*.yaml
```

### Step 4: Configure Kubernetes Secrets

**IMPORTANT: Update secrets before applying!**

```bash
# Generate base64 encoded secrets
echo -n "your-64-char-secret-key" | base64
echo -n "your-database-password" | base64

# Edit secrets.yaml with your values
nano k8s/secrets.yaml
```

### Step 5: Configure Ingress

Edit `k8s/ingress.yaml`:
- Update `host:` to your domain
- Create TLS secret with your certificates:

```bash
# Create TLS secret
kubectl create secret tls appstore-tls \
    --cert=/path/to/your/certificate.crt \
    --key=/path/to/your/private.key \
    -n nextcloud-appstore
```

### Step 6: Deploy to Kubernetes

```bash
# Apply all manifests using Kustomize
kubectl apply -k k8s/

# Or apply individually in order:
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/secrets.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/pvc.yaml
kubectl apply -f k8s/postgres-deployment.yaml

# Wait for PostgreSQL
kubectl wait --for=condition=ready pod -l app=postgres \
    -n nextcloud-appstore --timeout=120s

kubectl apply -f k8s/appstore-deployment.yaml
kubectl apply -f k8s/nginx-deployment.yaml
kubectl apply -f k8s/ingress.yaml
```

### Step 7: Import Database

```bash
# Get PostgreSQL pod name
PG_POD=$(kubectl get pod -l app=postgres -n nextcloud-appstore \
    -o jsonpath='{.items[0].metadata.name}')

# Import database dump
DB_DUMP=$(ls exports/appstore_db_*.sql.gz | sort -r | head -1)
gunzip -c "${DB_DUMP}" | kubectl exec -i "${PG_POD}" \
    -n nextcloud-appstore -- psql -U nextcloudappstore -d nextcloudappstore
```

### Step 8: Run Initial Setup Job (if not importing database)

```bash
# Only if starting fresh without database import
kubectl apply -f k8s/cronjob.yaml

# Trigger the initial setup job
kubectl create job --from=cronjob/appstore-initial-setup \
    initial-setup-manual -n nextcloud-appstore
```

### Step 9: Verify Deployment

```bash
# Check all pods are running
kubectl get pods -n nextcloud-appstore

# Check services
kubectl get svc -n nextcloud-appstore

# Check ingress
kubectl get ingress -n nextcloud-appstore

# View application logs
kubectl logs -f deployment/appstore -n nextcloud-appstore

# Test connectivity
kubectl port-forward svc/nginx-service 8080:80 -n nextcloud-appstore
curl http://localhost:8080/health/
```

---

## Maintenance

### Updating the Application

On staging (internet-connected):

```bash
# Update repository
git pull origin master

# Rebuild image with new version
APPSTORE_VERSION=v5.0.0 docker-compose build appstore

# Re-export and transfer to production
./scripts/build-and-export.sh
```

On production (disconnected):

```bash
# Load new image
docker load -i exports/nextcloudappstore_*.tar.gz

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

## Security Notes

1. **Always change default passwords** in `k8s/secrets.yaml`
2. **Generate a unique SECRET_KEY** for production
3. **Use proper TLS certificates** (not self-signed) in production
4. **Restrict network policies** in Kubernetes
5. **Regular backups** of PostgreSQL data
6. **Keep images updated** with security patches

---

## License

This deployment package is provided under the same license as the Nextcloud App Store (AGPL-3.0).
