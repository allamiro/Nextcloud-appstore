# RUN-DOCKER.md — Nextcloud App Store: Docker Compose Operator Runbook

> **Scope:** This guide covers the complete lifecycle using Docker Compose — from a blank server with nothing installed through to a fully operational air-gapped environment. For Kubernetes, see [RUN-K8s.md](RUN-K8s.md).

---

## Architecture

```
COMMERCIAL (internet-connected)              AIR-GAPPED (offline)
─────────────────────────────────            ──────────────────────────────
postgres          :5432 (internal)           postgres          :5432 (internal)
postgres-nc       :5432 (internal)           postgres-nc       :5432 (internal)
appstore          :8000 (internal)           appstore          :8000 (internal)
nginx             :80 / :443                 nginx             :30080 / :30443
fileserver        :8080 / :8443              fileserver        :30081 / :30444
nextcloud         :8081                      nextcloud         :8081
rustfs            :9000 (S3) / :9001 (UI)   rustfs            :9000 / :9001
rustfs-init       (one-shot bucket creator)  rustfs-init       (one-shot)
                                             db-import         (one-shot, first boot)
```

---

## Port Reference

### Commercial Stack (`docker-compose.yml`)

| Service | External Port | URL | Notes |
|---------|--------------|-----|-------|
| Nginx (HTTPS) | 443 | `https://{IP_ADDRESS}` | App Store UI + API |
| Nginx (HTTP) | 80 | `http://{IP_ADDRESS}` | Redirects to HTTPS |
| File Server (HTTPS) | 8443 | `https://{IP_ADDRESS}:8443/apps/` | App archives |
| File Server (HTTP) | 8080 | `http://{IP_ADDRESS}:8080/apps/` | App archives |
| Nextcloud | 8081 | `http://{IP_ADDRESS}:8081` | Nextcloud UI |
| RustFS S3 | 9000 | `http://{IP_ADDRESS}:9000` | S3 API endpoint |
| RustFS Console | 9001 | `http://{IP_ADDRESS}:9001` | Web UI |

### Air-Gapped Stack (`airgapped/docker-compose/docker-compose.airgapped.yml`)

| Service | External Port | URL | Notes |
|---------|--------------|-----|-------|
| Nginx (HTTPS) | 30443 | `https://{IP_ADDRESS}:30443` | App Store UI + API |
| Nginx (HTTP) | 30080 | `http://{IP_ADDRESS}:30080` | Redirects to HTTPS |
| File Server (HTTPS) | 30444 | `https://{IP_ADDRESS}:30444/apps/` | App archives |
| File Server (HTTP) | 30081 | `http://{IP_ADDRESS}:30081/apps/` | App archives |
| Nextcloud | 8081 | `http://{IP_ADDRESS}:8081` | Nextcloud UI |
| RustFS S3 | 9000 | `http://{IP_ADDRESS}:9000` | S3 API endpoint |
| RustFS Console | 9001 | `http://{IP_ADDRESS}:9001` | Web UI |

---

## Phase 1 — Commercial Setup (Internet-Connected)

### 1.1 Prerequisites

Install on the commercial server:

```bash
# Docker Engine
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker

# Docker Compose plugin
sudo apt-get install -y docker-compose-plugin

# Required tools
sudo apt-get install -y git openssl curl jq

# Verify
docker version
docker compose version
openssl version
```

Minimum resources: **4 CPU cores, 8 GB RAM, 60 GB disk** (more if mirroring all apps).

---

### 1.2 Clone and Configure

```bash
git clone https://github.com/allamiro/Nextcloud-appstore.git
cd Nextcloud-appstore

# Create your .env from the example
cp .env.example .env
```

Edit `.env` and set every value marked **CHANGE THIS**:

```bash
# Find your server IP
ip route get 1.1.1.1 | awk '{print $7; exit}'

# Generate a SECRET_KEY (no $ signs)
tr -dc 'a-zA-Z0-9_-' < /dev/urandom | head -c 64; echo
```

Key settings to change in `.env`:

| Variable | What to set |
|---|---|
| `APPSTORE_DOMAIN` | Your server IP or hostname |
| `FILESERVER_DOMAIN` | Same as above |
| `APPSTORE_API_URL` | `https://{IP_ADDRESS}/api/v1` |
| `FILE_SERVER_URL` | `https://{IP_ADDRESS}:8443/apps` |
| `SECRET_KEY` | 64-char random string (no $ chars) |
| `DB_PASSWORD` | Strong unique password |
| `NEXTCLOUD_ADMIN_PASSWORD` | Strong password |
| `NEXTCLOUD_DB_PASSWORD` | Strong unique password |
| `RUSTFS_ACCESS_KEY` | Username for RustFS |
| `RUSTFS_SECRET_KEY` | Strong password for RustFS |
| `GITHUB_API_TOKEN` | From https://github.com/settings/tokens |
| `ADMIN_USERNAME` | App Store Django admin username |
| `ADMIN_PASSWORD` | App Store Django admin password |
| `NEXTCLOUD_VERSION` | e.g. `30.0.1` |

> **WARNING:** Never commit `.env` to version control. It is in `.gitignore`.

---

### 1.3 Generate TLS Certificates

The stack uses a self-signed three-tier CA chain (Root CA → Intermediate CA → Server cert). Run this once:

```bash
# Generate for your server IP
SERVER_CN={IP_ADDRESS} \
SERVER_ALT_NAMES="IP:{IP_ADDRESS},DNS:localhost,DNS:appstore.local" \
bash k8s/generate-certs.sh
```

This creates:
- `k8s/certs/root-ca.crt` — Root CA (10 years)
- `k8s/certs/server-chain.crt` — Full chain for nginx
- `k8s/certs/server.key` — Private key
- `nginx/ssl/server.crt` — Auto-copied for Docker Compose nginx
- `nginx/ssl/server.key` — Auto-copied
- `nginx/ssl/root-ca.crt` — Auto-copied

> **Re-generate** when the server cert expires (1 year) or if the IP/hostname changes.

---

### 1.4 Trust the Root CA on Your Workstation

So your browser shows a green lock:

**macOS:**
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  k8s/certs/root-ca.crt
```

**Ubuntu/Debian:**
```bash
sudo cp k8s/certs/root-ca.crt /usr/local/share/ca-certificates/appstore-root-ca.crt
sudo update-ca-certificates
```

**CentOS/RHEL:**
```bash
sudo cp k8s/certs/root-ca.crt /etc/pki/ca-trust/source/anchors/appstore-root-ca.crt
sudo update-ca-trust extract
```

---

### 1.5 Start the Full Stack

```bash
./scripts/appstorectl.sh online up
```

This starts all eight services. First boot takes 2–3 minutes as:
- App Store runs migrations and loads fixtures
- Nextcloud auto-installs its database schema

Watch progress:
```bash
docker compose logs -f appstore    # App Store startup
docker compose logs -f nextcloud   # NC first-boot install
```

When `appstorectl.sh online up` returns, the App Store is ready. Nextcloud may need another 60 seconds to finish installing.

Verify:
```bash
# App Store
curl -k https://{IP_ADDRESS}/health/

# Nextcloud (wait for this to return JSON)
curl -s http://{IP_ADDRESS}:8081/status.php | python3 -m json.tool
```

---

### 1.6 Connect Nextcloud to the App Store

Run this once after Nextcloud finishes its first boot:

```bash
./scripts/appstorectl.sh online setup-nextcloud
```

This command:
1. Waits for Nextcloud to be fully ready
2. Copies `k8s/certs/root-ca.crt` into the Nextcloud container and runs `update-ca-certificates` so NC trusts the App Store's TLS cert
3. Calls `occ config:system:set appstoreurl` to point NC at your local App Store
4. Enables the App Store in NC settings
5. Tests that NC can actually reach the App Store API

If it fails, check:
```bash
docker logs nextcloud | tail -50
docker exec nextcloud php occ config:system:get appstoreurl
```

---

### 1.7 Sync App Metadata from Upstream

Pull all app metadata (names, descriptions, release versions, download URLs) from the official Nextcloud App Store:

```bash
# Test with a small batch first
./scripts/appstorectl.sh online sync --limit 20

# Full sync (takes 5–15 minutes, requires GITHUB_API_TOKEN in .env)
./scripts/appstorectl.sh online sync
```

Expected output:
```
New apps imported: 342
Translations added: 342
Screenshots added: 661
Total apps: 566+
Total releases: 14000+
```

After sync, the App Store UI at `https://{IP_ADDRESS}` shows all apps.

---

### 1.8 Build the App Allowlist

The allowlist controls which apps are included in the air-gapped export. Only allowlisted apps get their packages downloaded and bundled.

```bash
# Show current allowlist
./scripts/appstorectl.sh online apps allowlist list

# Add apps you need
./scripts/appstorectl.sh online apps allowlist add calendar
./scripts/appstorectl.sh online apps allowlist add contacts
./scripts/appstorectl.sh online apps allowlist add deck
./scripts/appstorectl.sh online apps allowlist add user_ldap
./scripts/appstorectl.sh online apps allowlist add files_pdfviewer
./scripts/appstorectl.sh online apps allowlist add talk

# Check DB status of each allowlisted app
./scripts/appstorectl.sh online apps allowlist status
```

The allowlist is stored in `config/app-allowlist.txt`. Edit it directly to bulk-add apps:
```bash
nano config/app-allowlist.txt
# One app ID per line; lines starting with # are comments
```

---

### 1.9 Check Compatibility

Verify each allowlisted app has a release compatible with your target Nextcloud version:

```bash
./scripts/appstorectl.sh online apps check-compat --nc-version 30.0.1
```

Output is saved to `exports/compatibility_30.0.1.json`. Review any apps flagged as incompatible and remove them from the allowlist or accept the gap.

---

### 1.10 Generate the Compatibility Report

```bash
./scripts/appstorectl.sh online apps report --nc-version 30.0.1
```

Creates:
- `exports/COMPATIBILITY_REPORT.csv` — spreadsheet-friendly
- `exports/COMPATIBILITY_REPORT.json` — machine-readable

Columns: `app_id`, `app_name`, `release_version`, `is_compatible`, `download_url`, `local_path`, `checksum_sha256`, `export_status`.

Review `export_status`:
- `downloaded` — ready to bundle
- `missing_archive` — package not yet downloaded
- `no_compatible_release` — app has no release for your NC version

---

### 1.11 Mirror Approved App Packages

Download the `.tar.gz` packages for all allowlisted+compatible apps:

```bash
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.1

# Force re-download if packages already exist
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.1 --force
```

Downloads go to `exports/app-archives/files/`. A `CHECKSUMS.sha256` file is generated alongside them.

Progress is shown per-app. Large allowlists may take 20–60 minutes depending on your internet connection.

---

### 1.12 Validate the Staging Deployment

```bash
./scripts/appstorectl.sh online test
```

Checks: all containers running, HTTPS endpoint, API response, fileserver access, DB integrity, Nextcloud integration.

All checks must pass before building the export bundle.

---

### 1.13 Set Up RustFS Object Storage

RustFS started with the stack in step 1.5. Buckets were auto-created by the `rustfs-init` service. Verify:

```bash
# Init buckets manually if rustfs-init failed
./scripts/appstorectl.sh online backup-rustfs init

# List all buckets
./scripts/appstorectl.sh online backup-rustfs ls

# Open the web console
echo "RustFS Console: http://{IP_ADDRESS}:9001"
echo "Login: $(grep RUSTFS_ACCESS_KEY .env | cut -d= -f2)"
```

To enable automatic upload after every export:
```bash
# In .env
USE_RUSTFS=true
```

Manual upload commands:
```bash
./scripts/appstorectl.sh online backup-rustfs db       # DB dump → backups bucket
./scripts/appstorectl.sh online backup-rustfs apps     # app archives → app-archives bucket
./scripts/appstorectl.sh online backup-rustfs bundle   # bundle → bundles bucket
./scripts/appstorectl.sh online backup-rustfs all      # all three
./scripts/appstorectl.sh online backup-rustfs ls backups   # list bucket contents
```

---

## Phase 2 — Build the Air-Gap Bundle

### 2.1 Export the Database

```bash
./scripts/appstorectl.sh online export-db
```

Creates `exports/appstore_db_TIMESTAMP.sql.gz` + SHA-256 checksum.

If `USE_RUSTFS=true`, the dump is automatically uploaded to the `backups` bucket.

---

### 2.2 Build the Full Bundle

```bash
./scripts/appstorectl.sh online export --nc-version 30.0.1
```

This 7-step process:
1. Generates the compatibility report
2. Downloads any missing approved app packages
3. Exports the App Store database
4. Saves all Docker images as `.tar.gz` files (App Store + Postgres + Nginx + Nextcloud + RustFS + mc)
5. Collects statistics
6. Writes `VERSION.txt` and `MANIFEST.json`
7. Generates `CHECKSUMS.sha256` for the entire bundle

Output: `nextcloud-appstore-airgap-TIMESTAMP.tar.gz` in the project root.

If `USE_RUSTFS=true`, the bundle and all metadata files are uploaded to the `bundles` bucket automatically.

---

### 2.3 What the Bundle Contains

```
nextcloud-appstore-airgap-TIMESTAMP.tar.gz
├── airgapped/
│   ├── images/
│   │   ├── nextcloudappstore__latest_TIMESTAMP.tar.gz
│   │   ├── postgres__15-alpine_TIMESTAMP.tar.gz
│   │   ├── nginx__alpine_TIMESTAMP.tar.gz
│   │   ├── nextcloud__stable-apache_TIMESTAMP.tar.gz
│   │   ├── rustfs__rustfs__latest_TIMESTAMP.tar.gz
│   │   └── minio__mc__latest_TIMESTAMP.tar.gz
│   └── exports/
│       ├── appstore_db_TIMESTAMP.sql.gz
│       ├── app-archives/files/*.tar.gz   (app packages)
│       ├── app-archives/CHECKSUMS.sha256
│       ├── MANIFEST.json
│       ├── VERSION.txt
│       ├── COMPATIBILITY_REPORT.csv
│       └── CHECKSUMS.sha256
├── k8s/                  (K8s manifests)
├── nginx/                (nginx config + ssl/)
├── fileserver/           (fileserver config)
├── config/               (app-allowlist.txt)
└── .env.example
```

---

### 2.4 Verify the Bundle

```bash
# Check checksums
sha256sum -c airgapped/exports/CHECKSUMS.sha256

# View the manifest
cat airgapped/exports/MANIFEST.json | python3 -m json.tool
```

---

## Phase 3 — Transfer to Air-Gapped Environment

### 3.1 What to Transfer

Option A — Transfer the single bundle archive:
```bash
ls -lh nextcloud-appstore-airgap-*.tar.gz
```

Option B — Transfer the `airgapped/` directory directly (avoids creating and extracting the archive):
```bash
rsync -av --progress airgapped/ user@airgap-host:/opt/nextcloud-appstore/airgapped/
rsync -av --progress nginx/ user@airgap-host:/opt/nextcloud-appstore/nginx/
rsync -av --progress fileserver/ user@airgap-host:/opt/nextcloud-appstore/fileserver/
rsync -av --progress scripts/ user@airgap-host:/opt/nextcloud-appstore/scripts/
```

### 3.2 Verify After Transfer

```bash
# On the air-gapped host
sha256sum -c airgapped/exports/CHECKSUMS.sha256
echo "Checksum verification: $?"
```

---

## Phase 4 — Air-Gapped Docker Compose Deployment

All steps in this phase run on the **air-gapped host** with no internet access.

### 4.1 Prerequisites on the Air-Gapped Host

```bash
# Docker Engine (installed while online, or from offline RPM/DEB)
docker version

# Docker Compose plugin
docker compose version

# Extract the bundle (if using archive transfer)
tar -xzf nextcloud-appstore-airgap-*.tar.gz
cd Nextcloud-appstore    # or wherever you placed the files
```

---

### 4.2 Configure the Air-Gapped Environment

```bash
cp airgapped/docker-compose/.env.airgapped.example airgapped/docker-compose/.env
nano airgapped/docker-compose/.env
```

Key settings for the air-gapped side:

| Variable | Value |
|---|---|
| `APPSTORE_DOMAIN` | Air-gapped server IP |
| `APPSTORE_API_URL` | `https://{IP_ADDRESS}:30443/api/v1` |
| `FILE_SERVER_URL` | `https://{IP_ADDRESS}:30444/apps` |
| `DB_PASSWORD` | Same as commercial (from exported DB) |
| `NEXTCLOUD_DB_PASSWORD` | Your chosen NC DB password |
| `SECRET_KEY` | Same as commercial (Django uses it to verify sessions) |
| `RUSTFS_ACCESS_KEY` | Your chosen RustFS username |
| `RUSTFS_SECRET_KEY` | Your chosen RustFS password |
| `NEXTCLOUD_ADMIN_PASSWORD` | Your NC admin password |

> **IMPORTANT:** `DB_PASSWORD` and `SECRET_KEY` must match the commercial values exactly — they are embedded in the exported database.

---

### 4.3 Copy TLS Certificates

Option A — Copy from the bundle (same certs, same IP):
```bash
# Certs were bundled in nginx/ssl/
ls nginx/ssl/
# server.crt  server.key  root-ca.crt  (already in place)
```

Option B — Regenerate for the air-gapped server's IP:
```bash
SERVER_CN={AIRGAP_IP} \
SERVER_ALT_NAMES="IP:{AIRGAP_IP},DNS:localhost,DNS:appstore.local" \
bash k8s/generate-certs.sh
# Certs auto-copied to nginx/ssl/
```

Trust the Root CA on the air-gapped host:
```bash
sudo cp k8s/certs/root-ca.crt /usr/local/share/ca-certificates/appstore-root-ca.crt
sudo update-ca-certificates
```

---

### 4.4 Load Docker Images

```bash
./scripts/appstorectl.sh airgap load-images
```

This loads every `.tar.gz` from `airgapped/images/` into Docker. No internet required.

Verify:
```bash
docker images | grep -E "(nextcloudappstore|postgres|nginx|nextcloud|rustfs|minio)"
```

You should see all six images: `nextcloudappstore:latest`, `postgres:15-alpine`, `nginx:alpine`, `nextcloud:stable-apache`, `rustfs/rustfs:latest`, `minio/mc:latest`.

---

### 4.5 Deploy the Full Stack

```bash
./scripts/appstorectl.sh airgap deploy compose
```

This brings up all services from `airgapped/docker-compose/docker-compose.airgapped.yml`:
- All services use `pull_policy: never`
- The `db-import` one-shot service automatically imports the App Store database from `exports/appstore_db_latest.sql.gz` if it exists
- `rustfs-init` creates the three RustFS buckets automatically

Watch startup:
```bash
docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml logs -f
```

Wait until you see the App Store health check pass:
```bash
curl -k https://{IP_ADDRESS}:30443/health/
# Expected: OK
```

Wait until Nextcloud is ready (takes ~90 seconds on first boot):
```bash
curl -s http://{IP_ADDRESS}:8081/status.php
# Expected: {"installed":true,...}
```

---

### 4.6 Verify the DB Import

The `db-import` service runs automatically. Check its result:

```bash
docker logs appstore-db-import
# Expected: "Import complete."
```

If the import failed or no dump was found:
```bash
# Manual import
DUMP=$(ls airgapped/exports/appstore_db_*.sql.gz | sort -r | head -1)
gunzip -c "${DUMP}" | docker exec -i appstore-postgres \
  psql -U nextcloudappstore -d nextcloudappstore
```

---

### 4.7 Initialise RustFS Buckets

The `rustfs-init` service created buckets automatically. Verify:

```bash
docker logs appstore-rustfs-init
# Expected: "RustFS buckets ready."

# Or manually
bash scripts/backup-to-rustfs.sh init
```

---

### 4.8 Connect Nextcloud to the Local App Store

```bash
./scripts/appstorectl.sh airgap configure-nextcloud
```

This uses `NEXTCLOUD_RUNTIME=compose` (default) and:
1. Backs up the current Nextcloud occ settings
2. Installs the App Store Root CA into the Nextcloud container
3. Sets `appstoreurl` to `https://{APPSTORE_DOMAIN}:30443/api/v1`
4. Enables `appstoreenabled`
5. Tests that Nextcloud can reach the App Store API
6. Rolls back on any failure and reports what went wrong

If Nextcloud is in a different location (SSH or K8s), set `NEXTCLOUD_RUNTIME=ssh` or `NEXTCLOUD_RUNTIME=k8s` in `.env` first.

---

### 4.9 Validate the Deployment

```bash
./scripts/appstorectl.sh airgap test compose
```

This runs a full validation suite covering:
- All service health checks
- HTTPS endpoints
- Database integrity (checks no public download URLs remain — must be 0)
- App archive availability on the fileserver
- Nextcloud integration (occ checks + sample API call)

All checks must pass. Any FAIL items need investigation before going live.

---

### 4.10 Access the Air-Gapped System

| Resource | URL |
|---|---|
| App Store (HTTPS) | `https://{IP_ADDRESS}:30443` |
| App Store Admin | `https://{IP_ADDRESS}:30443/admin/` |
| App Store API | `https://{IP_ADDRESS}:30443/api/v1/` |
| App Archives | `https://{IP_ADDRESS}:30444/apps/` |
| Nextcloud | `http://{IP_ADDRESS}:8081` |
| RustFS Console | `http://{IP_ADDRESS}:9001` |

Login credentials:
- **Nextcloud:** `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` from `.env`
- **App Store Admin:** `ADMIN_USERNAME` / `ADMIN_PASSWORD` from `.env`
- **RustFS Console:** `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` from `.env`

---

## Phase 5 — Update Cycle

### 5.1 On the Commercial Side (internet-connected)

```bash
# 1. Sync latest app metadata
./scripts/appstorectl.sh online sync

# 2. Check compatibility for new NC version (if updating NC)
./scripts/appstorectl.sh online apps check-compat --nc-version 30.0.2

# 3. Download new/updated packages
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.2

# 4. Build the new bundle
./scripts/appstorectl.sh online export --nc-version 30.0.2

# 5. Upload to RustFS for record-keeping
./scripts/appstorectl.sh online backup-rustfs all
```

### 5.2 Transfer the New Bundle

Same as Phase 3 — transfer `nextcloud-appstore-airgap-TIMESTAMP.tar.gz` or the `airgapped/` directory.

### 5.3 On the Air-Gapped Side

```bash
# Load new images only if images changed
./scripts/appstorectl.sh airgap load-images

# Import the new DB (the db-import service only runs once at first deploy)
# Run the import manually for subsequent updates:
DUMP=$(ls airgapped/exports/appstore_db_*.sql.gz | sort -r | head -1)
gunzip -c "${DUMP}" | docker exec -i appstore-postgres \
  psql -U nextcloudappstore -d nextcloudappstore

# Copy new app archives to fileserver volume
docker run --rm \
  -v "$(pwd)/airgapped/exports/app-archives/files:/src:ro" \
  -v appstore-fileserver_apps:/dst \
  alpine sh -c "cp -r /src/. /dst/"

# Restart App Store to pick up DB changes
docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml \
  restart appstore

# Validate
./scripts/appstorectl.sh airgap test compose
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `nginx: [emerg] cannot load certificate` | `nginx/ssl/` empty | Run `bash k8s/generate-certs.sh` |
| Nextcloud shows "App Store not reachable" | CA cert not trusted inside NC | Re-run `online setup-nextcloud` or `airgap configure-nextcloud` |
| `curl: (60) SSL certificate problem` | Root CA not trusted on host | Trust the Root CA (§1.4) |
| App Store 502 Bad Gateway | `appstore` container not ready | `docker logs appstore-app` — wait for uWSGI to start |
| DB import failed | Dump file path wrong | Ensure `airgapped/exports/appstore_db_latest.sql.gz` exists (symlink) |
| RustFS upload fails | Wrong IP in `.env` | Set `RUSTFS_HOST` to the actual server IP |
| `ERROR: No space left` on export | Disk full | Need ≥20 GB free; clean up old image tarballs |
| Nextcloud first boot stuck | NC DB not ready | `docker logs appstore-postgres-nc` — check DB health |

### Useful Commands

```bash
# Container status
docker compose ps

# Follow all logs
docker compose logs -f

# Follow a specific service
docker compose logs -f appstore

# Restart a single service
docker compose restart nginx

# Open a shell in a container
docker exec -it appstore-app bash

# Run an occ command in Nextcloud
docker exec -it nextcloud php occ list

# Check App Store DB
docker exec -it appstore-postgres psql -U nextcloudappstore -c "\dt"

# Check RustFS bucket contents
bash scripts/backup-to-rustfs.sh ls
bash scripts/backup-to-rustfs.sh ls backups
```

### Full Stack Teardown (use with care)

```bash
# Stop all services (keeps volumes)
docker compose down

# Stop AND remove all data volumes — DESTRUCTIVE
docker compose down -v

# Air-gapped stack
docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml down -v
```
