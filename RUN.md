# Operator Runbook — Nextcloud App Store Deployment Toolkit

This document covers every operational task for deploying and maintaining the Nextcloud App Store in both internet-connected (staging/online) and fully air-gapped environments.

---

## Table of Contents

1. [Overview and Architecture](#1-overview-and-architecture)
2. [Prerequisites](#2-prerequisites)
3. [Repository Layout](#3-repository-layout)
4. [First-Time Setup](#4-first-time-setup)
5. [Environment Variables Reference](#5-environment-variables-reference)
6. [Online Workflow: Start the Staging Stack](#6-online-workflow-start-the-staging-stack)
7. [Online Workflow: Sync App Metadata](#7-online-workflow-sync-app-metadata)
8. [App Allowlist Management](#8-app-allowlist-management)
9. [Compatibility Checking](#9-compatibility-checking)
10. [Generating a Compatibility Report](#10-generating-a-compatibility-report)
11. [Downloading Approved App Packages](#11-downloading-approved-app-packages)
12. [Mirroring All App Packages](#12-mirroring-all-app-packages)
13. [Exporting the Database](#13-exporting-the-database)
14. [Building the Export Bundle](#14-building-the-export-bundle)
15. [Building the Package Tarball](#15-building-the-package-tarball)
16. [Transferring to an Air-Gapped Host](#16-transferring-to-an-air-gapped-host)
17. [Loading Docker Images (Air-Gapped)](#17-loading-docker-images-air-gapped)
18. [Deploying with Docker Compose (Air-Gapped)](#18-deploying-with-docker-compose-air-gapped)
19. [Deploying on Kubernetes (Air-Gapped)](#19-deploying-on-kubernetes-air-gapped)
20. [TLS Certificate Management](#20-tls-certificate-management)
21. [Configuring Nextcloud — Docker Compose Target](#21-configuring-nextcloud--docker-compose-target)
22. [Configuring Nextcloud — Kubernetes Target](#22-configuring-nextcloud--kubernetes-target)
23. [Configuring Nextcloud — SSH / Bare-Metal Target](#23-configuring-nextcloud--ssh--bare-metal-target)
24. [Validating the Air-Gapped Deployment](#24-validating-the-air-gapped-deployment)
25. [Updating the App Catalog (Re-sync)](#25-updating-the-app-catalog-re-sync)
26. [Rotating the Database Password](#26-rotating-the-database-password)
27. [Backing Up and Restoring the Database](#27-backing-up-and-restoring-the-database)
28. [Scaling and High Availability Notes](#28-scaling-and-high-availability-notes)
29. [Troubleshooting: App Store Not Reachable](#29-troubleshooting-app-store-not-reachable)
30. [Troubleshooting: Nextcloud Shows Public App Store](#30-troubleshooting-nextcloud-shows-public-app-store)
31. [Troubleshooting: TLS / Certificate Errors](#31-troubleshooting-tls--certificate-errors)
32. [Troubleshooting: Database Import Failures](#32-troubleshooting-database-import-failures)
33. [Troubleshooting: App Package Download Failures](#33-troubleshooting-app-package-download-failures)
34. [Security Considerations](#34-security-considerations)
35. [Quick Reference — All appstorectl Commands](#35-quick-reference--all-appstorectl-commands)

---

## 1. Overview and Architecture

This toolkit wraps the upstream [Nextcloud App Store](https://github.com/nextcloud/appstore) Django application to provide:

- A fully private App Store that a Nextcloud instance queries instead of `apps.nextcloud.com`
- An offline-capable mirror of app packages served via a local HTTPS fileserver
- Tooling to build, transfer, and deploy the entire stack into air-gapped environments

### Services

| Service | Purpose | Port (local/NodePort) |
|---|---|---|
| `appstore` | Django/uWSGI App Store backend | 8000 (internal) |
| `nginx` | TLS termination + reverse proxy | 30443 |
| `postgres` | Database | 5432 (internal) |
| `fileserver` | nginx serving mirrored `.tar.gz` archives | 30444 |

### Communication path

```
Nextcloud ──HTTPS──► nginx:30443 ──► uWSGI:8000 (appstore)
                                          │
                                     PostgreSQL
Nextcloud ──HTTPS──► nginx:30444 (fileserver) ──► /var/www/html/apps/*.tar.gz
```

The `appstoreurl` Nextcloud config key must point to `https://<appstore-host>/api/v1` (note: `/api/v1` suffix, not just the root).

---

## 2. Prerequisites

### Online (staging) host

| Tool | Minimum version | Notes |
|---|---|---|
| Docker | 24+ | Compose plugin required (`docker compose`) |
| curl | any | For health checks |
| Python 3 | 3.9+ | For report generation scripts |
| sha256sum / shasum | any | For checksum generation |

### Air-gapped host

| Tool | Minimum version |
|---|---|
| Docker | 24+ (Compose) **or** Kubernetes 1.26+ |
| kubectl | 1.26+ (K8s deployments only) |

### Nextcloud instance being configured

- Running Nextcloud (any version ≥ 25)
- `php occ` available as `www-data`
- Network path from NC host to App Store host

---

## 3. Repository Layout

```
Nextcloud-appstore/
├── scripts/
│   ├── appstorectl.sh          ← Main CLI entry point
│   ├── export-bundle.sh        ← Full bundle builder
│   ├── sync-apps.sh            ← Sync from upstream App Store
│   ├── apps/
│   │   ├── manage-allowlist.sh
│   │   ├── check-compatibility.sh
│   │   ├── generate-report.sh
│   │   └── download-approved.sh
│   ├── mirror-apps/
│   │   ├── 01-extract-urls.sh
│   │   ├── 02-download-apps.sh
│   │   └── 03-update-db-urls.sh
│   └── db/
│       └── export-db.sh
├── airgapped/
│   ├── docker-compose/
│   │   ├── docker-compose.airgapped.yml
│   │   └── docker-compose.nextcloud-test.yml
│   ├── k8s/                    ← Air-gapped Kubernetes manifests
│   ├── scripts/
│   │   ├── load-images.sh
│   │   ├── deploy-compose-airgap.sh
│   │   ├── deploy-k8s-airgap.sh
│   │   ├── configure-nextcloud-compose.sh
│   │   ├── configure-nextcloud-k8s.sh
│   │   ├── configure-nextcloud-ssh.sh
│   │   └── test-airgap.sh
│   ├── images/                 ← Docker image tarballs (gitignored)
│   └── exports/                ← DB dumps, app archives, manifests (gitignored)
├── config/
│   └── app-allowlist.txt       ← Approved app IDs for export
├── k8s/                        ← Online/staging Kubernetes manifests
├── exports/                    ← Exports from online workflow (gitignored)
├── .env.example                ← Template — copy to .env
└── RUN.md                      ← This file
```

---

## 4. First-Time Setup

```bash
# 1. Clone the repository
git clone https://github.com/allamiro/Nextcloud-appstore.git
cd Nextcloud-appstore

# 2. Create your environment file
cp .env.example .env
$EDITOR .env   # Fill in passwords, domains, NC version

# 3. Generate TLS certificates (self-signed CA chain)
bash k8s/generate-certs.sh

# 4. Review the allowlist
cat config/app-allowlist.txt
# Uncomment or add the app IDs you want to export
```

The most critical `.env` values to set before first run:

| Variable | What to set |
|---|---|
| `SECRET_KEY` | Generate with: `tr -dc 'a-zA-Z0-9_-' < /dev/urandom \| head -c 64` |
| `DB_PASSWORD` | Strong random password |
| `APPSTORE_DOMAIN` | Hostname the App Store will be reached on |
| `FILE_SERVER_URL` | Base URL for mirrored app archives |
| `NEXTCLOUD_VERSION` | Target NC version (e.g. `30.0.1`) |

---

## 5. Environment Variables Reference

### App Store identity

| Variable | Default | Purpose |
|---|---|---|
| `APPSTORE_DOMAIN` | `appstore.local` | Hostname for the App Store |
| `FILESERVER_DOMAIN` | `files.local` | Hostname for the fileserver |
| `APPSTORE_API_URL` | `https://appstore.local/api/v1` | URL Nextcloud uses to query the store |
| `FILE_SERVER_URL` | `https://files.local/apps` | Base URL for mirrored packages |

### Nextcloud target version

| Variable | Default | Purpose |
|---|---|---|
| `NEXTCLOUD_VERSION` | *(required)* | Full version, e.g. `30.0.1` |
| `NEXTCLOUD_MAJOR_VERSION` | *(required)* | Major version number, e.g. `30` |

### Nextcloud runtime (for configure scripts)

| Variable | Values | Purpose |
|---|---|---|
| `NEXTCLOUD_RUNTIME` | `compose` \| `k8s` \| `ssh` \| `manual` | How NC is deployed |
| `NEXTCLOUD_CONTAINER_NAME` | `nextcloud` | Docker Compose container name |
| `NEXTCLOUD_K8S_NAMESPACE` | `nextcloud` | Kubernetes namespace for NC |
| `NEXTCLOUD_K8S_POD_SELECTOR` | `app=nextcloud` | Pod label selector |
| `NEXTCLOUD_SSH_HOST` | *(required for ssh)* | Remote hostname |
| `NEXTCLOUD_SSH_USER` | *(required for ssh)* | SSH username |
| `NEXTCLOUD_PATH` | `/var/www/html` | Path to NC on remote host |

### Packaging

| Variable | Default | Purpose |
|---|---|---|
| `AIRGAP_IMAGE_DIR` | `airgapped/images` | Where to save Docker image tarballs |
| `AIRGAP_EXPORT_DIR` | `airgapped/exports` | Where to save DB dumps and archives |
| `INCLUDE_MANAGED_NEXTCLOUD_IMAGES` | `false` | Include `nextcloud:stable-apache` in package |

---

## 6. Online Workflow: Start the Staging Stack

Run this on the internet-connected host where you build the deployment bundle.

```bash
./scripts/appstorectl.sh online up
```

This starts: `postgres`, `appstore`, `nginx`, `fileserver`.

Wait for the health check to pass (shown in output). The stack is ready when you see:

```
[INFO]  Staging stack is up
  App Store : https://localhost
  Admin     : https://localhost/admin/
```

To also start a managed test Nextcloud:

```bash
./scripts/appstorectl.sh online up managed-nextcloud
```

To check the stack status at any time:

```bash
./scripts/appstorectl.sh online audit
```

---

## 7. Online Workflow: Sync App Metadata

Pulls all app metadata from the official Nextcloud App Store API and stores it in the local database.

```bash
./scripts/appstorectl.sh online sync
```

To limit how many apps are synced (useful for testing):

```bash
./scripts/appstorectl.sh online sync --limit 50
```

The sync populates the `nextcloudappstore_core_app` and `nextcloudappstore_core_apprelease` tables. After syncing, the local App Store API at `https://localhost/api/v1/` returns the full app catalog.

---

## 8. App Allowlist Management

The allowlist at `config/app-allowlist.txt` controls which apps are included in compatibility checks and export bundles. If the file is empty (no uncommented lines), all synced apps are included.

```bash
# List all currently approved apps
./scripts/appstorectl.sh online apps allowlist list

# Add an app
./scripts/appstorectl.sh online apps allowlist add calendar
./scripts/appstorectl.sh online apps allowlist add contacts
./scripts/appstorectl.sh online apps allowlist add deck

# Remove an app
./scripts/appstorectl.sh online apps allowlist remove deck

# Show approval status for all synced apps
./scripts/appstorectl.sh online apps allowlist status
```

The `allowlist status` command queries the database and shows which synced apps are approved vs. not. It requires the App Store to be running.

App IDs are the technical identifiers used in the Nextcloud App Store (e.g. `calendar`, `contacts`, `user_ldap`). To find the correct ID: browse `https://localhost/api/v1/` or check `https://apps.nextcloud.com`.

---

## 9. Compatibility Checking

Check which approved apps have a release compatible with your target Nextcloud version.

```bash
# Uses NEXTCLOUD_VERSION from .env
./scripts/appstorectl.sh online apps check-compat

# Override version on the command line
./scripts/appstorectl.sh online apps check-compat --nc-version 30.0.1
```

Output example:

```
[INFO]  Checking app compatibility against Nextcloud 30.0.1

  Total approved apps : 25
  Compatible          : 23
  Not compatible      : 2

  COMPATIBLE apps:
    calendar                             v4.5.3       >=25.0.0,<31.0.0
    contacts                             v5.5.3       >=25.0.0,<31.0.0
    ...

  NOT COMPATIBLE apps:
    legacy_app                           no release for NC 30.0.1
```

Compatibility uses the `platform_version_spec` field from each release (semantic version range). Only the latest compatible release per app is shown.

The results are saved to `exports/compatibility_<version>.json` for use by the report generator.

---

## 10. Generating a Compatibility Report

Produces `exports/COMPATIBILITY_REPORT.csv` and `exports/COMPATIBILITY_REPORT.json` with full detail per app: version, platform spec, download URL, local archive path, checksum, approval status, and export status.

```bash
./scripts/appstorectl.sh online apps report --nc-version 30.0.1
```

CSV columns:

| Column | Description |
|---|---|
| `app_id` | Technical app identifier |
| `app_name` | Human-readable name |
| `release_version` | Latest compatible version |
| `platform_spec` | NC version range (e.g. `>=25.0.0,<31.0.0`) |
| `nc_target` | Nextcloud version being targeted |
| `is_compatible` | `True` / `False` |
| `download_url` | URL in the database (local or original) |
| `local_path` | Path to the local `.tar.gz` archive |
| `checksum_sha256` | SHA-256 of the local archive |
| `is_approved` | Always `True` for allowlisted apps |
| `export_status` | `downloaded` / `missing_archive` / `no_compatible_release` |

Apps with `export_status = missing_archive` need `download-approved.sh` to run.

---

## 11. Downloading Approved App Packages

Downloads `.tar.gz` packages only for allowlisted, compatible apps. Generates checksums. Skips already-present files unless `--force` is passed.

```bash
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.1

# Re-download everything even if already present
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.1 --force
```

Archives land in `exports/app-archives/files/` with a matching `CHECKSUMS.sha256`.

This is the preferred alternative to the full `online mirror` when you only want approved apps (smaller bundle, no URLs from non-approved apps rewritten).

---

## 12. Mirroring All App Packages

Mirrors every app in the database regardless of the allowlist. Rewrites download URLs in the database to point to the local fileserver.

```bash
./scripts/appstorectl.sh online mirror
```

This runs three steps in sequence:
1. Extract all download URLs from the database
2. Download all `.tar.gz` archives to `exports/app-archives/files/`
3. Rewrite database URLs to `${FILE_SERVER_URL}/<filename>`

After mirroring, export the database to capture the rewritten URLs:

```bash
./scripts/appstorectl.sh online export-db
```

**Note:** `online mirror` rewrites ALL app URLs, not just approved ones. If you only want approved apps, use `online apps mirror-approved` instead and re-export the DB after.

---

## 13. Exporting the Database

Dumps the PostgreSQL database to a gzipped SQL file.

```bash
./scripts/appstorectl.sh online export-db
```

Output: `exports/appstore_db_<timestamp>.sql.gz`

Always export the database **after** mirroring so the dump contains the rewritten local URLs. The air-gapped deployment imports this dump on first boot.

To check existing exports:

```bash
ls -lh exports/*.sql.gz
```

---

## 14. Building the Export Bundle

The export bundle is the complete, validated artifact for air-gapped deployment. It runs all steps in order and produces a tarball.

```bash
./scripts/appstorectl.sh online export --nc-version 30.0.1
```

This does:
1. Generates `COMPATIBILITY_REPORT.csv` / `.json`
2. Downloads any missing approved app packages
3. Exports the database
4. Saves Docker images as `.tar.gz`
5. Writes `VERSION.txt` and `MANIFEST.json`
6. Computes `CHECKSUMS.sha256`
7. Creates `nextcloud-appstore-airgap-<timestamp>.tar.gz`

To skip saving images (if you're transferring them separately):

```bash
./scripts/appstorectl.sh online export --nc-version 30.0.1 --skip-images
```

The `VERSION.txt` inside the bundle contains:

```
EXPORT_TIMESTAMP=20241201_120000
APPSTORE_VERSION=master
NEXTCLOUD_VERSION=30.0.1
TOTAL_APPROVED_APPS=25
COMPATIBLE_APPS=23
EXPORTED_PACKAGES=23
```

---

## 15. Building the Package Tarball

For a quick package of the deployment scripts and images only (without the full compatibility pipeline):

```bash
./scripts/appstorectl.sh package build

# Include the managed test Nextcloud image
./scripts/appstorectl.sh package build --include-managed-nextcloud
```

This builds the `nextcloudappstore:latest` Docker image, saves all required images, copies the DB dump and app archives, and creates a tarball.

Use `online export` instead when you want the full manifest, report, and checksum coverage.

---

## 16. Transferring to an Air-Gapped Host

### Option A: Single tarball

```bash
# On the online host
scp nextcloud-appstore-airgap-<timestamp>.tar.gz user@airgap-host:/opt/

# On the air-gapped host
cd /opt
tar -xzf nextcloud-appstore-airgap-<timestamp>.tar.gz
cd Nextcloud-appstore
cp .env.example .env
$EDITOR .env   # Set passwords and domains for this environment
```

### Option B: rsync the directory

```bash
rsync -av --exclude='.git' \
    Nextcloud-appstore/ \
    user@airgap-host:/opt/Nextcloud-appstore/
```

### Option C: Physical media

Copy the tarball to a USB drive or other physical media. Verify checksums after transfer:

```bash
sha256sum -c airgapped/exports/CHECKSUMS.sha256
```

---

## 17. Loading Docker Images (Air-Gapped)

On the air-gapped host, load the saved images into Docker. This verifies SHA-256 checksums automatically if `.sha256` sidecar files are present.

```bash
./scripts/appstorectl.sh airgap load-images
```

Verify images are available:

```bash
docker images | grep -E "nextcloudappstore|postgres|nginx"
```

Expected output:

```
nextcloudappstore   latest    <id>   ...
postgres            15-alpine <id>   ...
nginx               alpine    <id>   ...
```

---

## 18. Deploying with Docker Compose (Air-Gapped)

```bash
./scripts/appstorectl.sh airgap deploy compose
```

This:
1. Links the latest DB dump as `appstore_db_latest.sql.gz`
2. Starts the Compose stack (postgres, appstore, nginx, fileserver)
3. The `db-import` service runs once and imports the SQL dump
4. Waits for the appstore health endpoint

After deployment:

```bash
# Check all containers
docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml ps

# View logs
docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml logs -f

# App Store is available at:
curl -k https://localhost:30443/health/
```

To include the managed test Nextcloud:

```bash
docker compose \
  -f airgapped/docker-compose/docker-compose.airgapped.yml \
  -f airgapped/docker-compose/docker-compose.nextcloud-test.yml \
  up -d
```

---

## 19. Deploying on Kubernetes (Air-Gapped)

```bash
./scripts/appstorectl.sh airgap deploy k8s
```

This applies manifests in order (`01-namespace.yaml` through `11-configure-nextcloud-job.yaml`) with `imagePullPolicy: Never`. A DB import Job runs once after the postgres pod is ready.

Monitor the deployment:

```bash
kubectl get pods -n nextcloud-appstore -w
kubectl logs job/appstore-db-import -n nextcloud-appstore
```

All manifests use `imagePullPolicy: Never` — Docker images must be loaded first (section 17).

To use a different kubectl context:

```bash
KUBECTL_CONTEXT=my-cluster ./scripts/appstorectl.sh airgap deploy k8s
```

---

## 20. TLS Certificate Management

The App Store uses a self-signed CA chain generated by `k8s/generate-certs.sh`:
- `k8s/certs/root-ca.crt` — Root CA certificate (distribute this to NC hosts)
- `k8s/certs/appstore.crt` / `appstore.key` — Server certificate

### Regenerate certificates

```bash
bash k8s/generate-certs.sh
```

After regenerating, restart the stack so nginx picks up the new certs.

### Check certificate expiry

```bash
openssl x509 -in k8s/certs/appstore.crt -noout -dates
```

### Trust the CA in different environments

**Docker (add to Nextcloud container):**
```bash
docker cp k8s/certs/root-ca.crt nextcloud:/usr/local/share/ca-certificates/appstore-root-ca.crt
docker exec nextcloud update-ca-certificates
docker restart nextcloud
```

**Kubernetes (create ConfigMap):**
```bash
kubectl create configmap appstore-ca \
  --from-file=appstore-root-ca.crt=k8s/certs/root-ca.crt \
  -n nextcloud
# Then mount it in your NC Deployment and run update-ca-certificates
```

**Bare-metal:**
```bash
sudo cp k8s/certs/root-ca.crt /usr/local/share/ca-certificates/appstore-root-ca.crt
sudo update-ca-certificates
```

The `configure-nextcloud-*.sh` scripts install the CA certificate automatically when `k8s/certs/root-ca.crt` exists. Pass `--no-ca` to skip.

---

## 21. Configuring Nextcloud — Docker Compose Target

Configures a Nextcloud instance running as a Docker Compose service on the same or a reachable host.

```bash
./scripts/appstorectl.sh airgap configure-nextcloud external-compose
```

Required `.env` variables:

```bash
NEXTCLOUD_CONTAINER_NAME=nextcloud   # Container name
APPSTORE_API_URL=https://appstore.local/api/v1
```

The script:
1. Backs up the current `appstoreurl` and `appstoreenabled` values
2. Installs the CA cert (if available)
3. Sets `appstoreenabled=true` and `appstoreurl` (idempotent — skips if already correct)
4. Tests connectivity from inside the NC container to the App Store API
5. Rolls back on failure

To skip CA installation or connectivity test:

```bash
NEXTCLOUD_CONTAINER_NAME=nextcloud \
  bash airgapped/scripts/configure-nextcloud-compose.sh --no-ca --no-test
```

---

## 22. Configuring Nextcloud — Kubernetes Target

```bash
./scripts/appstorectl.sh airgap configure-nextcloud external-k8s
```

Required `.env` variables:

```bash
NEXTCLOUD_K8S_NAMESPACE=nextcloud
NEXTCLOUD_K8S_POD_SELECTOR=app=nextcloud
NEXTCLOUD_K8S_CONTAINER=nextcloud
APPSTORE_API_URL=https://appstore.local/api/v1
```

The script finds the pod by label selector, backs up config, applies the changes idempotently, tests connectivity, and rolls back on failure.

If the CA ConfigMap approach doesn't work for your NC setup (e.g. read-only filesystem), mount the cert via a volume in your NC Deployment spec instead, then pass `--no-ca`:

```bash
bash airgapped/scripts/configure-nextcloud-k8s.sh --no-ca
```

---

## 23. Configuring Nextcloud — SSH / Bare-Metal Target

```bash
./scripts/appstorectl.sh airgap configure-nextcloud external-ssh
```

Required `.env` variables:

```bash
NEXTCLOUD_SSH_HOST=192.168.1.100
NEXTCLOUD_SSH_USER=ubuntu
NEXTCLOUD_PATH=/var/www/html
APPSTORE_API_URL=https://appstore.local/api/v1
```

SSH key authentication must be set up in advance (`ssh-copy-id` or authorized_keys). The script does not prompt for a password.

The connectivity test runs from the remote host using `curl` (or `wget` / PHP as fallback). If it fails, the previous `appstoreurl` is restored automatically.

---

## 24. Validating the Air-Gapped Deployment

Run the full validation suite after deployment and after configuring Nextcloud:

```bash
# Docker Compose
./scripts/appstorectl.sh airgap test compose

# Kubernetes
./scripts/appstorectl.sh airgap test k8s
```

The test script checks:
- All services/pods are running/ready
- App Store `/health/` responds over HTTPS
- `/api/v1/` returns valid JSON
- Fileserver is reachable
- **All app download URLs in the DB point to the local fileserver (no public internet URLs)**
- At least one app package is downloadable from the local fileserver
- If Nextcloud is configured: `appstoreurl` is set correctly and `app:list` returns results

A successful run with no failures means the deployment is ready to serve apps to Nextcloud.

---

## 25. Updating the App Catalog (Re-sync)

To update the app catalog after a period of time (on the online host):

```bash
# 1. Ensure the stack is running
./scripts/appstorectl.sh online up

# 2. Sync new metadata
./scripts/appstorectl.sh online sync

# 3. Check compatibility with target NC version
./scripts/appstorectl.sh online apps check-compat

# 4. Update the allowlist if needed
./scripts/appstorectl.sh online apps allowlist add new_app

# 5. Download new/updated packages
./scripts/appstorectl.sh online apps mirror-approved

# 6. Re-export database (with rewritten URLs)
./scripts/appstorectl.sh online export-db

# 7. Build and transfer new bundle
./scripts/appstorectl.sh online export --nc-version 30.0.1
```

On the air-gapped host, to update without redeploying from scratch:

```bash
# 1. Load any new images
./scripts/appstorectl.sh airgap load-images

# 2. Copy updated app archives to the fileserver volume
# (path depends on your deployment)

# 3. Import the new DB dump
docker exec -i appstore-postgres psql -U nextcloudappstore nextcloudappstore \
  < airgapped/exports/appstore_db_<new_timestamp>.sql
```

---

## 26. Rotating the Database Password

1. Update `DB_PASSWORD` in `.env`
2. Stop the stack
3. Update the postgres user password:
   ```bash
   docker exec -it appstore-postgres \
     psql -U postgres -c "ALTER USER nextcloudappstore PASSWORD 'new_password';"
   ```
4. Restart the stack
5. Verify the App Store reconnects:
   ```bash
   curl -k https://localhost:30443/health/
   ```

For Kubernetes: update the secret in `k8s/02-secrets.yaml`, apply it, and restart the appstore deployment.

---

## 27. Backing Up and Restoring the Database

### Manual backup

```bash
docker exec appstore-postgres \
  pg_dump -U nextcloudappstore nextcloudappstore | gzip \
  > exports/appstore_db_manual_$(date +%Y%m%d).sql.gz
```

### Scheduled backup (cron)

```bash
# Add to crontab — daily at 2am
0 2 * * * cd /opt/Nextcloud-appstore && \
  ./scripts/appstorectl.sh online export-db >> logs/export.log 2>&1
```

### Restore from backup

```bash
# Stop the appstore container first to avoid write conflicts
docker stop appstore-app

# Drop and recreate the database
docker exec appstore-postgres \
  psql -U postgres -c "DROP DATABASE IF EXISTS nextcloudappstore; \
    CREATE DATABASE nextcloudappstore OWNER nextcloudappstore;"

# Import the dump
gunzip -c exports/appstore_db_<timestamp>.sql.gz \
  | docker exec -i appstore-postgres \
    psql -U nextcloudappstore nextcloudappstore

# Restart
docker start appstore-app
```

---

## 28. Scaling and High Availability Notes

The App Store backend is stateless (state is in PostgreSQL). For high availability:

- Run multiple `appstore` container replicas behind the nginx upstream
- Use an external managed PostgreSQL (update `DATABASE_HOST` in `.env`)
- The fileserver is purely static files — serve from object storage (MinIO, S3) for scale

For Kubernetes, increase replica count in `k8s/06-appstore.yaml`:

```yaml
spec:
  replicas: 3
```

The `db-import` Job (`k8s/10-import-db-job.yaml`) and `configure-nextcloud` Job (`k8s/11-configure-nextcloud-job.yaml`) are one-shot — they will not re-run unless deleted and recreated.

---

## 29. Troubleshooting: App Store Not Reachable

**Symptom:** `curl -k https://<host>:30443/health/` times out or refuses connection.

```bash
# Check all containers/pods are running
./scripts/appstorectl.sh airgap test compose   # or k8s

# Check nginx logs
docker logs appstore-nginx --tail 50

# Check appstore logs
docker logs appstore-app --tail 50

# Check the appstore is listening on uWSGI port
docker exec appstore-app ss -tlnp | grep 8000
```

**Common causes:**
- nginx can't reach the appstore via uWSGI socket — check `nginx/nginx.conf` `upstream` block
- The appstore container crashed on startup — check `docker logs appstore-app` for Django errors
- Port 30443 is blocked by a firewall rule

---

## 30. Troubleshooting: Nextcloud Shows Public App Store

**Symptom:** After configuring, Nextcloud still shows apps from `apps.nextcloud.com`.

```bash
# Verify the OCC config was applied
docker exec -u www-data nextcloud php occ config:system:get appstoreurl
docker exec -u www-data nextcloud php occ config:system:get appstoreenabled

# Force Nextcloud to clear its app list cache
docker exec -u www-data nextcloud php occ app:update --all
```

**Common causes:**
- The configure script pointed at the wrong container — check `NEXTCLOUD_CONTAINER_NAME`
- A `config.php` override or `config.d/` file is overriding `appstoreurl`
- Nextcloud is caching the app list — wait 5 minutes or clear the cache with `occ maintenance:repair`
- The configured URL is wrong — it must end with `/api/v1`, not just the domain root

---

## 31. Troubleshooting: TLS / Certificate Errors

**Symptom:** `curl: (60) SSL certificate problem: unable to get local issuer certificate`

```bash
# Test with CA provided explicitly
curl --cacert k8s/certs/root-ca.crt https://<appstore-host>:30443/health/

# Check certificate details
openssl s_client -connect <appstore-host>:30443 -CAfile k8s/certs/root-ca.crt

# Check certificate is valid for the domain
openssl x509 -in k8s/certs/appstore.crt -noout -text | grep -A1 "Subject Alternative"
```

If the certificate doesn't include the hostname you're using, regenerate with `bash k8s/generate-certs.sh` and add the correct SAN.

Inside a Nextcloud container that rejects the cert:

```bash
docker exec nextcloud curl -v https://<appstore-host>:30443/api/v1/
# Then install the CA cert (section 20) and retry
```

---

## 32. Troubleshooting: Database Import Failures

**Symptom:** App Store starts but returns no apps or gives Django database errors.

```bash
# Check if import ran
docker logs appstore-db-import --tail 50   # Compose
kubectl logs job/appstore-db-import -n nextcloud-appstore   # K8s

# Check the DB directly
docker exec appstore-postgres \
  psql -U nextcloudappstore nextcloudappstore \
  -c "SELECT count(*) FROM nextcloudappstore_core_app;"

# Re-run import manually
gunzip -c airgapped/exports/appstore_db_latest.sql.gz \
  | docker exec -i appstore-postgres \
    psql -U nextcloudappstore nextcloudappstore
```

**Common causes:**
- The `appstore_db_latest.sql.gz` symlink is broken — check `ls -la airgapped/exports/`
- The dump was created with a different postgres user — check the dump header with `zcat dump.sql.gz | head -20`
- The database already has data and the import conflicts — drop and recreate (section 27)

---

## 33. Troubleshooting: App Package Download Failures

**Symptom:** Nextcloud users try to install an app and get a download error.

```bash
# Check whether the file exists on the fileserver
curl -k https://localhost:30444/apps/

# Try downloading the specific package
curl -kfsSL https://localhost:30444/apps/<appname>.tar.gz -o /tmp/test.tar.gz

# Check the DB for the download URL stored for that app
docker exec appstore-postgres \
  psql -U nextcloudappstore nextcloudappstore \
  -c "SELECT app_id, version, download FROM nextcloudappstore_core_apprelease \
      WHERE app_id = 'calendar' ORDER BY version DESC LIMIT 3;"

# List files on the fileserver volume
docker exec appstore-fileserver ls /var/www/html/apps/ | head -20
```

**Common causes:**
- The archive was not downloaded — run `online apps mirror-approved` or `online mirror`
- The URL in the DB still points to the original source — re-run `03-update-db-urls.sh` and re-export
- The file exists but permissions prevent nginx from serving it

---

## 34. Security Considerations

- **Never commit `.env`** — it contains database passwords and the Django secret key
- **Rotate `SECRET_KEY`** before production — use `tr -dc 'a-zA-Z0-9_-' < /dev/urandom | head -c 64`
- **Avoid `$` in `SECRET_KEY`** — Docker Compose interprets it as variable expansion
- **Rate limiting** — configured via `THROTTLE_*` variables in `.env`; defaults are conservative
- **Admin interface** — exposed at `/admin/`; restrict access at the nginx level if needed
- **CA certificate** — the private key at `k8s/certs/root-ca.key` should never leave the online host; only distribute `root-ca.crt`
- **App package integrity** — `download-approved.sh` generates SHA-256 checksums; validate them on the air-gapped host before importing
- **No outbound connections** — once deployed in air-gapped mode, the App Store stack makes no outbound connections; verify with the `test-airgap.sh` suite

---

## 35. Quick Reference — All appstorectl Commands

```bash
# ── Online ────────────────────────────────────────────────────────────────────
./scripts/appstorectl.sh online audit
./scripts/appstorectl.sh online up
./scripts/appstorectl.sh online up managed-nextcloud
./scripts/appstorectl.sh online sync
./scripts/appstorectl.sh online sync --limit 50

# App management
./scripts/appstorectl.sh online apps allowlist list
./scripts/appstorectl.sh online apps allowlist add <app_id>
./scripts/appstorectl.sh online apps allowlist remove <app_id>
./scripts/appstorectl.sh online apps allowlist status
./scripts/appstorectl.sh online apps check-compat [--nc-version X.Y.Z]
./scripts/appstorectl.sh online apps report [--nc-version X.Y.Z]
./scripts/appstorectl.sh online apps mirror-approved [--nc-version X.Y.Z] [--force]

# Mirror and export
./scripts/appstorectl.sh online mirror
./scripts/appstorectl.sh online export-db
./scripts/appstorectl.sh online export [--nc-version X.Y.Z] [--skip-images]

# Configure Nextcloud
./scripts/appstorectl.sh online configure-nextcloud external-compose
./scripts/appstorectl.sh online configure-nextcloud external-k8s
./scripts/appstorectl.sh online configure-nextcloud external-ssh

./scripts/appstorectl.sh online test

# ── Package ───────────────────────────────────────────────────────────────────
./scripts/appstorectl.sh package build
./scripts/appstorectl.sh package build --include-managed-nextcloud

# ── Air-Gapped ────────────────────────────────────────────────────────────────
./scripts/appstorectl.sh airgap load-images
./scripts/appstorectl.sh airgap deploy compose
./scripts/appstorectl.sh airgap deploy k8s
./scripts/appstorectl.sh airgap configure-nextcloud external-compose
./scripts/appstorectl.sh airgap configure-nextcloud external-k8s
./scripts/appstorectl.sh airgap configure-nextcloud external-ssh
./scripts/appstorectl.sh airgap test compose
./scripts/appstorectl.sh airgap test k8s
```
