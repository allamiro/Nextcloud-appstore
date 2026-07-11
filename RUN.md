# Operator Runbook — Nextcloud App Store Deployment Toolkit

This runbook covers the complete lifecycle of the Nextcloud App Store deployment toolkit, starting from zero on both sides — no Nextcloud, no App Store installed anywhere. Follow it in order.

---

## Overview

This toolkit deploys two things as a single integrated stack:

1. **A private Nextcloud App Store** — a full replica of `apps.nextcloud.com` that your Nextcloud queries instead of the public internet
2. **Nextcloud itself** — deployed alongside the App Store and configured to use it automatically

There are two environments:

| Environment | Has internet | Purpose |
|---|---|---|
| **Commercial** | Yes | Sync app catalog, mirror packages, build export bundle |
| **Air-gapped** | No | Production deployment from pre-built bundle |

The workflow is always: **Commercial → bundle → transfer → Air-gapped**.

---

## Table of Contents

**Phase 1 — Commercial: Initial Setup**
1. [Prerequisites](#1-prerequisites)
2. [Repository Setup and Configuration](#2-repository-setup-and-configuration)
3. [Generate TLS Certificates](#3-generate-tls-certificates)
4. [Start the Full Stack](#4-start-the-full-stack)
5. [Connect Nextcloud to the Local App Store](#5-connect-nextcloud-to-the-local-app-store)
6. [Verify the Commercial Deployment](#6-verify-the-commercial-deployment)

**Phase 2 — Commercial: Build the Export Bundle**
7. [Sync App Metadata from Upstream](#7-sync-app-metadata-from-upstream)
8. [Manage the App Allowlist](#8-manage-the-app-allowlist)
9. [Check Compatibility with Your Nextcloud Version](#9-check-compatibility-with-your-nextcloud-version)
10. [Download Approved App Packages](#10-download-approved-app-packages)
11. [Generate the Compatibility Report](#11-generate-the-compatibility-report)
12. [Export the Database](#12-export-the-database)
13. [Build the Air-Gapped Export Bundle](#13-build-the-air-gapped-export-bundle)
14. [Verify the Bundle](#14-verify-the-bundle)

**Phase 3 — Transfer**
15. [Transfer the Bundle to the Air-Gapped Host](#15-transfer-the-bundle-to-the-air-gapped-host)

**Phase 4 — Air-Gapped: Deployment**
16. [Air-Gapped Prerequisites](#16-air-gapped-prerequisites)
17. [Configure the Air-Gapped Environment File](#17-configure-the-air-gapped-environment-file)
18. [Load Docker Images](#18-load-docker-images)
19. [Deploy the Full Stack (Docker Compose)](#19-deploy-the-full-stack-docker-compose)
20. [Deploy the Full Stack (Kubernetes)](#20-deploy-the-full-stack-kubernetes)
21. [Connect Nextcloud to the Local App Store](#21-connect-nextcloud-to-the-local-app-store)
22. [Validate the Air-Gapped Deployment](#22-validate-the-air-gapped-deployment)
23. [Access Nextcloud and Confirm Apps Load](#23-access-nextcloud-and-confirm-apps-load)

**Phase 5 — Update Cycle**
24. [Update the App Catalog on the Commercial Side](#24-update-the-app-catalog-on-the-commercial-side)
25. [Build and Transfer an Updated Bundle](#25-build-and-transfer-an-updated-bundle)
26. [Apply the Update in the Air-Gapped Environment](#26-apply-the-update-in-the-air-gapped-environment)

**Operations Reference**
27. [TLS Certificate Management](#27-tls-certificate-management)
28. [Rotating Passwords](#28-rotating-passwords)
29. [Backing Up and Restoring the Database](#29-backing-up-and-restoring-the-database)
30. [Troubleshooting: Stack Won't Start](#30-troubleshooting-stack-wont-start)
31. [Troubleshooting: Nextcloud Shows Public App Store](#31-troubleshooting-nextcloud-shows-public-app-store)
32. [Troubleshooting: TLS Certificate Errors](#32-troubleshooting-tls-certificate-errors)
33. [Troubleshooting: App Packages Not Downloading](#33-troubleshooting-app-packages-not-downloading)
34. [Troubleshooting: Database Import Failures](#34-troubleshooting-database-import-failures)
35. [Quick Reference — All Commands](#35-quick-reference--all-commands)

---

# Phase 1 — Commercial: Initial Setup

## 1. Prerequisites

The following tools must be installed on the **commercial (internet-connected) host**:

| Tool | Version | Check |
|---|---|---|
| Docker + Compose plugin | 24+ | `docker compose version` |
| OpenSSL | any | `openssl version` |
| curl | any | `curl --version` |
| Python 3 | 3.9+ | `python3 --version` |
| git | any | `git --version` |

```bash
# Quick check — all should return a version, not "command not found"
docker compose version
openssl version
curl --version
python3 --version
```

---

## 2. Repository Setup and Configuration

```bash
# Clone the repository
git clone https://github.com/allamiro/Nextcloud-appstore.git
cd Nextcloud-appstore

# Create your environment file from the template
cp .env.example .env
```

Open `.env` and fill in these values **before starting anything**:

```bash
# ==========================================================
# Minimum required values — everything else has safe defaults
# ==========================================================

# Generate a unique secret key (never use the default in production):
# tr -dc 'a-zA-Z0-9_-' < /dev/urandom | head -c 64; echo
SECRET_KEY=<64-char random string — no $ characters>

# App Store database password
DB_PASSWORD=<strong random password>

# Nextcloud database password (separate from App Store)
NEXTCLOUD_DB_PASSWORD=<strong random password>

# Nextcloud admin login
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=<strong password>

# The hostname this App Store will be reached on
APPSTORE_DOMAIN=appstore.yourdomain.local

# The hostname where mirrored app packages will be served
FILESERVER_DOMAIN=files.yourdomain.local

# URL Nextcloud uses to query the local App Store (must end with /api/v1)
APPSTORE_API_URL=https://appstore.yourdomain.local/api/v1

# Base URL for downloading mirrored app packages
FILE_SERVER_URL=https://files.yourdomain.local/apps

# The exact Nextcloud version you are deploying (for compatibility filtering)
NEXTCLOUD_VERSION=30.0.1
NEXTCLOUD_MAJOR_VERSION=30

# GitHub API token — required for syncing Nextcloud releases
GITHUB_API_TOKEN=ghp_your_token_here
```

---

## 3. Generate TLS Certificates

The App Store uses a self-signed CA chain so that Nextcloud can verify its identity. Generate it once:

```bash
bash k8s/generate-certs.sh
```

This creates:
- `k8s/certs/root-ca.crt` — Root CA certificate (distribute to Nextcloud hosts)
- `k8s/certs/root-ca.key` — Root CA private key (never leave the commercial host)
- `k8s/certs/appstore.crt` / `appstore.key` — Server certificate for nginx

**Keep `k8s/certs/root-ca.key` on the commercial host only.** Copy only `root-ca.crt` to other systems.

---

## 4. Start the Full Stack

```bash
./scripts/appstorectl.sh online up
```

This starts all services:
- `postgres` — App Store database
- `postgres-nc` — Nextcloud database
- `appstore` — Django/uWSGI App Store backend
- `nginx` — TLS reverse proxy for the App Store
- `fileserver` — HTTPS server for mirrored app archives
- `nextcloud` — Nextcloud (auto-installs on first boot)

Expected output:

```
[INFO]  Stack is up

  App Store  : https://localhost
  Admin      : https://localhost/admin/
  File Srv   : http://localhost:8080/apps/
  Nextcloud  : http://localhost:8081  (installing — wait ~60s on first boot)

[INFO]  Next step: wait for Nextcloud to finish installing, then run:
  ./scripts/appstorectl.sh online setup-nextcloud
```

Check that all services are running:

```bash
docker compose ps
```

All six services should show `Up` or `healthy`.

**Wait for Nextcloud to finish its first-boot installation** before proceeding. You can watch the logs:

```bash
docker logs -f nextcloud
# Ready when you see: "Nextcloud was successfully installed"
```

---

## 5. Connect Nextcloud to the Local App Store

Once Nextcloud finishes installing:

```bash
./scripts/appstorectl.sh online setup-nextcloud
```

This command:
1. Waits for Nextcloud to be fully ready
2. Copies the App Store CA certificate into the Nextcloud container and runs `update-ca-certificates`
3. Sets `appstoreenabled = true` via `php occ`
4. Sets `appstoreurl = https://appstore.local/api/v1` (or your configured domain)
5. Tests that Nextcloud can actually reach and query the App Store API
6. Rolls back the configuration if the connectivity test fails

If the test passes, you will see:

```
[OK]    Connectivity test passed — Nextcloud can reach the App Store.
[OK]    Configuration complete.
```

---

## 6. Verify the Commercial Deployment

```bash
./scripts/appstorectl.sh online test
```

All checks should pass. Then open Nextcloud in a browser:

```
http://localhost:8081
```

Log in with `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` from `.env`, then navigate to **Apps**. The app list should load from your local App Store (it will be mostly empty until you sync — that's expected at this point).

---

# Phase 2 — Commercial: Build the Export Bundle

## 7. Sync App Metadata from Upstream

Pull all app metadata from the official Nextcloud App Store. This requires the `GITHUB_API_TOKEN` set in `.env`.

```bash
./scripts/appstorectl.sh online sync
```

This populates your local database with the full catalog of Nextcloud apps. The sync may take several minutes. When complete, refreshing the Apps page in Nextcloud should show the full catalog.

To limit the sync to a smaller set for testing:

```bash
./scripts/appstorectl.sh online sync --limit 50
```

---

## 8. Manage the App Allowlist

The allowlist at `config/app-allowlist.txt` controls which apps are included in the air-gapped bundle. If the file has no active (non-commented) lines, all synced apps are included.

**Add only the apps your organization needs** — this keeps the bundle small and avoids downloading thousands of packages you won't use.

```bash
# See what's in the allowlist
./scripts/appstorectl.sh online apps allowlist list

# Add apps you need
./scripts/appstorectl.sh online apps allowlist add calendar
./scripts/appstorectl.sh online apps allowlist add contacts
./scripts/appstorectl.sh online apps allowlist add user_ldap
./scripts/appstorectl.sh online apps allowlist add twofactor_totp

# See which synced apps are approved vs. not
./scripts/appstorectl.sh online apps allowlist status
```

App IDs are the technical identifiers (e.g. `calendar`, `contacts`, `deck`). To find them, browse `https://apps.nextcloud.com` or query the local App Store at `https://localhost/api/v1/`.

---

## 9. Check Compatibility with Your Nextcloud Version

Verify which approved apps have a release compatible with `NEXTCLOUD_VERSION` from your `.env`:

```bash
./scripts/appstorectl.sh online apps check-compat
```

Or specify the version explicitly:

```bash
./scripts/appstorectl.sh online apps check-compat --nc-version 30.0.1
```

Sample output:

```
  Total approved apps : 12
  Compatible          : 11
  Not compatible      : 1

  COMPATIBLE apps:
    calendar          v4.5.3    >=25.0.0,<31.0.0
    contacts          v5.5.3    >=25.0.0,<31.0.0
    user_ldap         v1.15.0   >=25.0.0,<31.0.0
    ...

  NOT COMPATIBLE apps:
    legacy_app        no release for NC 30.0.1
```

Apps with no compatible release will not be downloaded or included in the bundle. Remove them from the allowlist or choose a different NC version.

---

## 10. Download Approved App Packages

Download the `.tar.gz` packages for all approved, compatible apps:

```bash
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.1
```

This:
- Downloads only allowlisted + compatible packages (skips existing files)
- Generates `exports/app-archives/CHECKSUMS.sha256`
- Outputs download progress per app

To re-download everything:

```bash
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.1 --force
```

After downloading, the database URLs must be rewritten so they point to your local fileserver instead of `apps.nextcloud.com`. Run the full mirror command to do this:

```bash
./scripts/appstorectl.sh online mirror
```

This rewrites every `download` URL in the database for apps that have a local copy, then you need to re-export the database.

---

## 11. Generate the Compatibility Report

```bash
./scripts/appstorectl.sh online apps report --nc-version 30.0.1
```

Produces:
- `exports/COMPATIBILITY_REPORT.csv` — spreadsheet format
- `exports/COMPATIBILITY_REPORT.json` — machine-readable format

The report shows per-app: version, platform spec, local archive path, checksum, and `export_status` (`downloaded` / `missing_archive` / `no_compatible_release`). All apps should show `downloaded` before proceeding to the bundle build.

---

## 12. Export the Database

Export the App Store database **after** downloading and mirroring (so the dump contains rewritten local URLs):

```bash
./scripts/appstorectl.sh online export-db
```

Output: `exports/appstore_db_<timestamp>.sql.gz`

This dump is imported on first boot in the air-gapped environment to give the deployed App Store its full catalog with correct local URLs.

---

## 13. Build the Air-Gapped Export Bundle

This is the single command that packages everything for transfer:

```bash
./scripts/appstorectl.sh online export --nc-version 30.0.1
```

What it produces:

| File/Directory | Contents |
|---|---|
| `nextcloud-appstore-airgap-<ts>.tar.gz` | Everything below, in one tarball |
| `airgapped/images/*.tar.gz` | Docker images: appstore, postgres, nginx, **nextcloud** |
| `airgapped/images/*.sha256` | SHA-256 checksum per image |
| `airgapped/exports/appstore_db_<ts>.sql.gz` | App Store database dump |
| `airgapped/exports/app-archives/files/*.tar.gz` | App packages |
| `airgapped/exports/app-archives/CHECKSUMS.sha256` | Package checksums |
| `airgapped/exports/VERSION.txt` | Human-readable export manifest |
| `airgapped/exports/MANIFEST.json` | Machine-readable manifest |
| `airgapped/exports/COMPATIBILITY_REPORT.csv` | Per-app compatibility |
| `airgapped/exports/CHECKSUMS.sha256` | Checksums of all export files |
| `airgapped/exports/ALLOWLIST.txt` | Copy of the allowlist |

To skip saving images (if you're transferring them separately):

```bash
./scripts/appstorectl.sh online export --nc-version 30.0.1 --skip-images
```

---

## 14. Verify the Bundle

Confirm the bundle is complete and checksums match:

```bash
# Check the manifest
cat airgapped/exports/VERSION.txt

# Verify file checksums
cd airgapped/exports
sha256sum -c CHECKSUMS.sha256
cd -

# List what's in the tarball
ls -lh nextcloud-appstore-airgap-*.tar.gz
```

The `VERSION.txt` should show:

```
EXPORT_TIMESTAMP=...
APPSTORE_VERSION=master
NEXTCLOUD_VERSION=30.0.1
TOTAL_APPROVED_APPS=12
COMPATIBLE_APPS=11
EXPORTED_PACKAGES=11
```

---

# Phase 3 — Transfer

## 15. Transfer the Bundle to the Air-Gapped Host

### Option A: Single tarball via scp

```bash
scp nextcloud-appstore-airgap-<timestamp>.tar.gz \
    user@airgap-host:/opt/deployments/
```

On the air-gapped host:

```bash
cd /opt/deployments
tar -xzf nextcloud-appstore-airgap-<timestamp>.tar.gz
```

### Option B: rsync the directory (if SSH is available between environments)

```bash
rsync -av --progress \
    --exclude='.git' \
    --exclude='exports/app-archives/files/' \
    Nextcloud-appstore/ \
    user@airgap-host:/opt/Nextcloud-appstore/

# Then sync app archives separately (they can be large)
rsync -av exports/app-archives/files/ \
    user@airgap-host:/opt/Nextcloud-appstore/airgapped/exports/app-archives/files/
```

### Option C: Physical media

Copy the tarball to encrypted USB or other physical media. After copying:

```bash
# Verify integrity on the air-gapped host
sha256sum nextcloud-appstore-airgap-<timestamp>.tar.gz
# Compare against the sha256 you recorded on the commercial host
```

---

# Phase 4 — Air-Gapped: Deployment

## 16. Air-Gapped Prerequisites

The following must be installed on the **air-gapped host** before deployment:

| Tool | Version |
|---|---|
| Docker + Compose plugin | 24+ |

No internet access is required or used after this point. All images come from the bundle.

```bash
# Verify Docker is available
docker compose version
```

---

## 17. Configure the Air-Gapped Environment File

After extracting the bundle:

```bash
cd /opt/Nextcloud-appstore   # or wherever you extracted to

cp .env.example .env
$EDITOR .env
```

**Critical values to set for the air-gapped environment:**

```bash
# ==========================================================
# Must match what was used on the commercial side
# OR set to values appropriate for this host
# ==========================================================

# Passwords — should match what's in the bundle's DB dump
DB_PASSWORD=<same as commercial>
NEXTCLOUD_DB_PASSWORD=<same as commercial>

# NC admin credentials
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=<same as commercial>

# The hostname this App Store will be reached on IN THIS ENVIRONMENT
APPSTORE_DOMAIN=appstore.internal
FILESERVER_DOMAIN=files.internal

# The URL Nextcloud will use to reach the App Store
APPSTORE_API_URL=https://appstore.internal/api/v1

# The URL for downloading app packages
FILE_SERVER_URL=https://files.internal/apps

# Django secret key — can be the same as commercial
SECRET_KEY=<same 64-char string from commercial>

# Allowed hosts for Django — must include the airgap hostname
ALLOWED_HOSTS=localhost,127.0.0.1,appstore.internal
```

> **Note on domains:** If you are using different hostnames in the air-gapped environment than on the commercial side (e.g. `appstore.internal` instead of `appstore.yourdomain.local`), you must regenerate the TLS certificate for the new hostname before loading images:
>
> ```bash
> APPSTORE_DOMAIN=appstore.internal bash k8s/generate-certs.sh
> ```

---

## 18. Load Docker Images

```bash
./scripts/appstorectl.sh airgap load-images
```

This loads all `.tar.gz` images from `airgapped/images/` into Docker and verifies their SHA-256 checksums. After loading, verify:

```bash
docker images
```

You should see all four images:

```
nextcloudappstore   latest          <id>   ...
nextcloud           stable-apache   <id>   ...
postgres            15-alpine       <id>   ...
nginx               alpine          <id>   ...
```

---

## 19. Deploy the Full Stack (Docker Compose)

```bash
./scripts/appstorectl.sh airgap deploy compose
```

This starts all services using the pre-loaded images (no internet access):
- `postgres` — App Store database
- `postgres-nc` — Nextcloud database
- `db-import` — one-shot job that imports the App Store DB dump
- `appstore` — App Store backend
- `nginx` — TLS reverse proxy
- `fileserver` — App package server
- `nextcloud` — Nextcloud (auto-installs on first boot)

Monitor the deployment:

```bash
# Watch all containers come up
docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml ps

# Watch the DB import complete
docker logs appstore-db-import -f

# Watch Nextcloud install (takes ~60s)
docker logs nextcloud -f
# Ready when you see: "Nextcloud was successfully installed"
```

Expected service endpoints after deployment:

| Service | URL |
|---|---|
| Nextcloud | http://localhost:8081 |
| App Store HTTPS | https://localhost:30443 |
| App Store admin | https://localhost:30443/admin/ |
| File server | https://localhost:30444/apps/ |

---

## 20. Deploy the Full Stack (Kubernetes)

If deploying on Kubernetes instead:

```bash
./scripts/appstorectl.sh airgap deploy k8s
```

This applies manifests in order (`01-namespace.yaml` through `11-configure-nextcloud-job.yaml`). All manifests use `imagePullPolicy: Never` since images were loaded in step 18.

Monitor:

```bash
kubectl get pods -n nextcloud-appstore -w
kubectl logs job/appstore-db-import -n nextcloud-appstore
```

---

## 21. Connect Nextcloud to the Local App Store

Once Nextcloud finishes installing (step 19/20), connect it to the App Store:

```bash
./scripts/appstorectl.sh airgap configure-nextcloud
```

This script:
1. Waits for Nextcloud to be fully ready
2. Installs the App Store CA certificate inside Nextcloud (`update-ca-certificates`)
3. Sets `appstoreenabled = true` via `php occ`
4. Sets `appstoreurl` to your local App Store URL
5. Tests that Nextcloud can reach the App Store API from inside the container
6. Rolls back the configuration if the connectivity test fails

On success:

```
[OK]    Connectivity test passed — Nextcloud can reach the App Store.
[OK]    Configuration complete.
```

---

## 22. Validate the Air-Gapped Deployment

Run the full validation suite:

```bash
./scripts/appstorectl.sh airgap test compose
# or
./scripts/appstorectl.sh airgap test k8s
```

The suite checks:
- All services are running and healthy
- App Store `/health/` endpoint responds
- App Store `/api/v1/` returns valid JSON
- Fileserver is reachable
- **All download URLs in the database point to the local fileserver** (no `apps.nextcloud.com`)
- At least one app package is downloadable from the local fileserver
- Nextcloud `appstoreurl` is set to the local App Store
- `php occ app:list` works (confirms NC can query the store)

All checks must pass. Warnings indicate incomplete setup (e.g. no packages mirrored yet).

---

## 23. Access Nextcloud and Confirm Apps Load

```
http://localhost:8081
```

Log in with the admin credentials from `.env`. Navigate to **Apps**.

You should see the full app catalog from your local App Store. Installing an app from this list downloads the package from the local fileserver (`https://localhost:30444`) — not from the internet.

To confirm an app installs correctly:

```bash
docker exec -u www-data nextcloud php occ app:install calendar
docker exec -u www-data nextcloud php occ app:list | grep calendar
```

---

# Phase 5 — Update Cycle

## 24. Update the App Catalog on the Commercial Side

On the commercial host, when you need to add new apps or update existing ones:

```bash
# 1. Ensure the commercial stack is running
./scripts/appstorectl.sh online up

# 2. Pull updated metadata from upstream App Store
./scripts/appstorectl.sh online sync

# 3. Update the allowlist if you want new apps
./scripts/appstorectl.sh online apps allowlist add new_app

# 4. Re-check compatibility
./scripts/appstorectl.sh online apps check-compat --nc-version 30.0.1

# 5. Download updated/new packages
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.1

# 6. Rewrite URLs (for any newly downloaded packages)
./scripts/appstorectl.sh online mirror

# 7. Re-export the database
./scripts/appstorectl.sh online export-db
```

---

## 25. Build and Transfer an Updated Bundle

```bash
# Build the new bundle (only changed app packages need downloading again)
./scripts/appstorectl.sh online export --nc-version 30.0.1

# Transfer to air-gapped host
scp nextcloud-appstore-airgap-<new-timestamp>.tar.gz \
    user@airgap-host:/opt/deployments/
```

You don't need to transfer the Docker images again unless the App Store image was rebuilt or the Nextcloud version changed.

To transfer only the new data files (faster for updates):

```bash
# Transfer only DB dump and new app archives
scp airgapped/exports/appstore_db_<new-timestamp>.sql.gz \
    user@airgap-host:/opt/Nextcloud-appstore/airgapped/exports/

rsync -av --progress exports/app-archives/files/ \
    user@airgap-host:/opt/Nextcloud-appstore/airgapped/exports/app-archives/files/
```

---

## 26. Apply the Update in the Air-Gapped Environment

On the air-gapped host:

```bash
cd /opt/Nextcloud-appstore

# Update the symlink to point to the new dump
ln -sf appstore_db_<new-timestamp>.sql.gz \
    airgapped/exports/appstore_db_latest.sql.gz

# Import the new database dump into the running postgres
gunzip -c airgapped/exports/appstore_db_latest.sql.gz \
    | docker exec -i appstore-postgres \
      psql -U nextcloudappstore nextcloudappstore

# The App Store serves from the DB — no restart needed
# Verify the catalog updated
curl -k https://localhost:30443/api/v1/ | python3 -m json.tool | head -30
```

New app packages placed in `airgapped/exports/app-archives/files/` are served immediately by the fileserver (no restart required).

Then re-validate:

```bash
./scripts/appstorectl.sh airgap test compose
```

---

# Operations Reference

## 27. TLS Certificate Management

### Generate/regenerate certificates

```bash
bash k8s/generate-certs.sh
```

Run this any time the certificate expires or you change the `APPSTORE_DOMAIN`. After regenerating, restart nginx to pick up the new cert:

```bash
docker restart appstore-nginx
```

### Check certificate expiry

```bash
openssl x509 -in k8s/certs/appstore.crt -noout -dates
```

### Check certificate covers your hostname

```bash
openssl x509 -in k8s/certs/appstore.crt -noout -text \
    | grep -A3 "Subject Alternative"
```

If the certificate doesn't cover the hostname, regenerate it:

```bash
APPSTORE_DOMAIN=appstore.yourdomain.local bash k8s/generate-certs.sh
```

### Manually trust the CA in Nextcloud

```bash
docker cp k8s/certs/root-ca.crt \
    nextcloud:/usr/local/share/ca-certificates/appstore-root-ca.crt
docker exec nextcloud update-ca-certificates
docker restart nextcloud
```

---

## 28. Rotating Passwords

### App Store database password

1. Update `DB_PASSWORD` in `.env`
2. Change the password in postgres:
   ```bash
   docker exec appstore-postgres \
       psql -U postgres -c "ALTER USER nextcloudappstore PASSWORD 'newpass';"
   ```
3. Restart the appstore container:
   ```bash
   docker restart appstore-app
   ```

### Nextcloud database password

1. Update `NEXTCLOUD_DB_PASSWORD` in `.env`
2. Change the password:
   ```bash
   docker exec appstore-postgres-nc \
       psql -U postgres -c "ALTER USER nextcloud PASSWORD 'newpass';"
   ```
3. Restart Nextcloud:
   ```bash
   docker restart nextcloud
   ```

### Nextcloud admin password

```bash
docker exec -u www-data nextcloud \
    php occ user:resetpassword admin
```

---

## 29. Backing Up and Restoring the Database

### App Store database backup

```bash
./scripts/appstorectl.sh online export-db
# Output: exports/appstore_db_<timestamp>.sql.gz
```

### Manual backup

```bash
docker exec appstore-postgres \
    pg_dump -U nextcloudappstore nextcloudappstore \
    | gzip > exports/appstore_db_manual_$(date +%Y%m%d).sql.gz
```

### Restore from backup

```bash
# Stop the appstore container first
docker stop appstore-app

# Drop and recreate the database
docker exec appstore-postgres psql -U postgres -c \
    "DROP DATABASE IF EXISTS nextcloudappstore;
     CREATE DATABASE nextcloudappstore OWNER nextcloudappstore;"

# Import
gunzip -c exports/appstore_db_<timestamp>.sql.gz \
    | docker exec -i appstore-postgres \
      psql -U nextcloudappstore nextcloudappstore

# Restart
docker start appstore-app
```

### Nextcloud database backup

```bash
docker exec appstore-postgres-nc \
    pg_dump -U nextcloud nextcloud \
    | gzip > exports/nextcloud_db_$(date +%Y%m%d).sql.gz
```

---

## 30. Troubleshooting: Stack Won't Start

```bash
# See what's running and what failed
docker compose ps

# Check logs for a specific service
docker compose logs appstore --tail 50
docker compose logs nextcloud --tail 50
docker compose logs nginx --tail 50

# Check if TLS certs exist (nginx will fail without them)
ls -la k8s/certs/
# Must have: root-ca.crt, appstore.crt, appstore.key

# If certs are missing, generate them
bash k8s/generate-certs.sh
```

Common causes:
- **Certs missing**: Run `bash k8s/generate-certs.sh`
- **Port already in use**: Another process on 80, 443, 8081. Find and stop it: `sudo lsof -i :443`
- **DB password mismatch**: Ensure `DB_PASSWORD` / `NEXTCLOUD_DB_PASSWORD` match between `.env` and running containers. Delete volumes and restart to re-initialize: `docker compose down -v && docker compose up -d`

---

## 31. Troubleshooting: Nextcloud Shows Public App Store

**Symptom:** After configuration, Nextcloud's Apps page still shows apps from `apps.nextcloud.com`.

```bash
# Check the current OCC configuration
docker exec -u www-data nextcloud php occ config:system:get appstoreurl
docker exec -u www-data nextcloud php occ config:system:get appstoreenabled

# Expected:
# appstoreurl = https://appstore.local/api/v1   (or your configured domain)
# appstoreenabled = true

# If not set, re-run setup
./scripts/appstorectl.sh online setup-nextcloud   # commercial
# or
./scripts/appstorectl.sh airgap configure-nextcloud  # air-gapped

# Clear Nextcloud's app cache
docker exec -u www-data nextcloud php occ maintenance:repair
```

If `appstoreurl` is correct but apps still come from the internet:
- Check `config/config.php` inside the NC volume for any override
- Check `config/config.d/` for a file overriding `appstoreurl`

---

## 32. Troubleshooting: TLS Certificate Errors

**Symptom:** `curl: (60) SSL certificate problem` or Nextcloud shows a connection error to the App Store.

```bash
# Test TLS from outside
curl -k https://localhost:30443/health/       # -k = ignore cert errors
curl --cacert k8s/certs/root-ca.crt https://localhost:30443/health/  # with CA

# Test from inside the Nextcloud container
docker exec nextcloud curl -v https://appstore.local/api/v1/

# If that fails but this works, the CA cert isn't trusted:
docker exec nextcloud curl -kv https://appstore.local/api/v1/
```

**Fix — reinstall the CA cert:**

```bash
docker cp k8s/certs/root-ca.crt \
    nextcloud:/usr/local/share/ca-certificates/appstore-root-ca.crt
docker exec nextcloud update-ca-certificates
docker restart nextcloud
```

**Check the cert covers your domain:**

```bash
openssl s_client -connect localhost:30443 2>/dev/null \
    | openssl x509 -noout -text | grep -A3 "Subject Alternative"
```

If the hostname isn't listed, regenerate the cert:

```bash
APPSTORE_DOMAIN=appstore.your-new-domain bash k8s/generate-certs.sh
docker restart appstore-nginx
```

---

## 33. Troubleshooting: App Packages Not Downloading

**Symptom:** Nextcloud can list apps but fails when a user tries to install one.

```bash
# Check the URL stored in the DB for the failing app
docker exec appstore-postgres \
    psql -U nextcloudappstore nextcloudappstore \
    -c "SELECT app_id, version, download FROM nextcloudappstore_core_apprelease \
        WHERE app_id = 'calendar' ORDER BY version DESC LIMIT 3;"

# The download URL should point to your fileserver, not apps.nextcloud.com

# Check the file exists on the fileserver
curl -k https://localhost:30444/apps/ | grep calendar

# Try downloading directly
curl -kfsSL https://localhost:30444/apps/<filename>.tar.gz -o /tmp/test.tar.gz
```

**Fix — if URLs still point to `apps.nextcloud.com`:**

```bash
# Run the mirror URL rewrite step
bash scripts/mirror-apps/03-update-db-urls.sh

# Re-export the database
./scripts/appstorectl.sh online export-db

# In air-gapped: re-import the new dump (section 26)
```

**Fix — if the file is missing from the fileserver:**

```bash
# Re-run the download step
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.1
```

---

## 34. Troubleshooting: Database Import Failures

**Symptom:** The App Store starts but shows no apps, or Django gives database errors.

```bash
# Check if the import ran
docker logs appstore-db-import

# Check if the DB has any data
docker exec appstore-postgres \
    psql -U nextcloudappstore nextcloudappstore \
    -c "SELECT count(*) FROM nextcloudappstore_core_app;"

# Check that the dump file exists and is not empty
ls -lh airgapped/exports/appstore_db_latest.sql.gz
file airgapped/exports/appstore_db_latest.sql.gz
```

**Fix — re-run the import manually:**

```bash
docker stop appstore-app

# Drop and recreate the database
docker exec appstore-postgres psql -U postgres -c \
    "DROP DATABASE IF EXISTS nextcloudappstore;
     CREATE DATABASE nextcloudappstore OWNER nextcloudappstore;"

# Import
gunzip -c airgapped/exports/appstore_db_latest.sql.gz \
    | docker exec -i appstore-postgres \
      psql -U nextcloudappstore nextcloudappstore

docker start appstore-app
```

**Fix — if the dump is from the wrong environment:**

The dump must have been created on a stack with `FILE_SERVER_URL` set to a URL reachable from the air-gapped environment. If it still contains `apps.nextcloud.com` URLs, regenerate it on the commercial side after running the mirror step.

---

## 35. Quick Reference — All Commands

```bash
# ── COMMERCIAL SIDE ───────────────────────────────────────────────────────────

# First-time setup
./scripts/appstorectl.sh online up
./scripts/appstorectl.sh online setup-nextcloud

# Sync and populate
./scripts/appstorectl.sh online sync
./scripts/appstorectl.sh online apps allowlist list
./scripts/appstorectl.sh online apps allowlist add <app_id>
./scripts/appstorectl.sh online apps allowlist remove <app_id>
./scripts/appstorectl.sh online apps check-compat --nc-version 30.0.1
./scripts/appstorectl.sh online apps report --nc-version 30.0.1
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.1
./scripts/appstorectl.sh online mirror
./scripts/appstorectl.sh online export-db

# Build export bundle
./scripts/appstorectl.sh online export --nc-version 30.0.1

# Diagnostics
./scripts/appstorectl.sh online audit
./scripts/appstorectl.sh online test

# ── AIR-GAPPED SIDE ──────────────────────────────────────────────────────────

# First-time deployment
./scripts/appstorectl.sh airgap load-images
./scripts/appstorectl.sh airgap deploy compose     # or: deploy k8s
./scripts/appstorectl.sh airgap configure-nextcloud
./scripts/appstorectl.sh airgap test compose       # or: test k8s

# ── PACKAGE BUILD (alternative to online export) ─────────────────────────────

./scripts/appstorectl.sh package build
```
