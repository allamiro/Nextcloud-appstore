# Nextcloud App Store — Docker Compose Operator Runbook

> **Scope:** Complete operator guide for deploying the Nextcloud App Store system using
> Docker Compose. Covers the full lifecycle from a bare host with nothing installed, through
> the commercial (internet-connected) build, air-gap bundle creation, transfer, offline
> deployment, and the recurring update cycle.
>
> This guide uses `{IP_ADDRESS}` as a placeholder wherever you must substitute your actual
> server IP address or hostname. Replace every occurrence with your real value before running
> any command.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Port Reference](#port-reference)
3. [Access URLs](#access-urls)
4. [PHASE 1 — Commercial Setup (internet-connected)](#phase-1--commercial-setup-internet-connected)
5. [PHASE 2 — Build the Air-Gap Bundle](#phase-2--build-the-air-gap-bundle)
6. [PHASE 3 — Transfer to the Air-Gapped Environment](#phase-3--transfer-to-the-air-gapped-environment)
7. [PHASE 4 — Air-Gapped Docker Compose Deployment](#phase-4--air-gapped-docker-compose-deployment)
8. [PHASE 5 — Update Cycle](#phase-5--update-cycle)
9. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

The system is composed of two separate environments that mirror each other.

**Commercial side** (`docker-compose.yml`) — requires internet access for initial setup:

| Service | Role | Image |
|---|---|---|
| `postgres` | App Store's PostgreSQL database | `postgres:15-alpine` |
| `postgres-nc` | Nextcloud's dedicated PostgreSQL | `postgres:15-alpine` |
| `appstore` | Django/uWSGI application server | `nextcloudappstore:latest` (built locally) |
| `nginx` | TLS reverse proxy for the App Store | `nginx:alpine` |
| `fileserver` | nginx serving mirrored `.tar.gz` archives | `nginx:alpine` |
| `nextcloud` | Nextcloud instance for integration testing | `nextcloud:stable-apache` |
| `rustfs` | S3-compatible object store | `rustfs/rustfs:latest` |
| `rustfs-init` | One-shot bucket creator | `minio/mc:latest` |

**Air-gapped side** (`airgapped/docker-compose/docker-compose.airgapped.yml`) — no internet:

Identical services but all carry `pull_policy: never` so Docker never attempts to contact a
registry. Adds one extra service:

| Service | Role |
|---|---|
| `db-import` | One-shot job that imports the App Store DB dump on first start |

---

## Port Reference

### Commercial Stack (`docker-compose.yml`)

| Port (host) | Service | Protocol | Purpose |
|---|---|---|---|
| 80 | nginx | HTTP | Redirect to HTTPS |
| 443 | nginx | HTTPS | App Store web UI and API |
| 8080 | fileserver | HTTP | App archive downloads (plain HTTP) |
| 8443 | fileserver | HTTPS | App archive downloads (TLS) |
| 8081 | nextcloud | HTTP | Nextcloud web UI |
| 9000 | rustfs | HTTP | S3-compatible API endpoint |
| 9001 | rustfs | HTTP | RustFS web console |

### Air-Gapped Stack (`airgapped/docker-compose/docker-compose.airgapped.yml`)

| Port (host) | Service | Protocol | Purpose |
|---|---|---|---|
| 30080 | nginx | HTTP | Redirect to HTTPS |
| 30443 | nginx | HTTPS | App Store web UI and API |
| 30081 | fileserver | HTTP | App archive downloads (plain HTTP) |
| 30444 | fileserver | HTTPS | App archive downloads (TLS) |
| 8081 | nextcloud | HTTP | Nextcloud web UI |
| 9000 | rustfs | HTTP | S3-compatible API endpoint |
| 9001 | rustfs | HTTP | RustFS web console |

---

## Access URLs

Replace `{IP_ADDRESS}` with your server's actual IP address or hostname.

### Commercial (Online) Environment

| Service | URL | Notes |
|---|---|---|
| App Store web UI | `https://{IP_ADDRESS}/` | Django admin user from `.env` |
| App Store admin panel | `https://{IP_ADDRESS}/admin/` | `ADMIN_USERNAME` / `ADMIN_PASSWORD` |
| App Store API v1 | `https://{IP_ADDRESS}/api/v1/` | public |
| App Store health check | `https://{IP_ADDRESS}/health/` | returns `OK` |
| File server (HTTPS) | `https://{IP_ADDRESS}:8443/apps/` | public directory listing |
| Nextcloud | `http://{IP_ADDRESS}:8081/` | `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` |
| RustFS S3 API | `http://{IP_ADDRESS}:9000/` | `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` |
| RustFS web console | `http://{IP_ADDRESS}:9001/` | `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` |

### Air-Gapped Environment

| Service | URL | Notes |
|---|---|---|
| App Store web UI | `https://{IP_ADDRESS}:30443/` | Django admin user from `.env` |
| App Store admin panel | `https://{IP_ADDRESS}:30443/admin/` | `ADMIN_USERNAME` / `ADMIN_PASSWORD` |
| App Store API v1 | `https://{IP_ADDRESS}:30443/api/v1/` | public |
| App Store health check | `https://{IP_ADDRESS}:30443/health/` | returns `OK` |
| File server (HTTPS) | `https://{IP_ADDRESS}:30444/apps/` | public directory listing |
| Nextcloud | `http://{IP_ADDRESS}:8081/` | `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` |
| RustFS S3 API | `http://{IP_ADDRESS}:9000/` | `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` |
| RustFS web console | `http://{IP_ADDRESS}:9001/` | `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` |

---

## PHASE 1 — Commercial Setup (internet-connected)

This phase is performed on a machine that has internet access. The goal is to stand up the
full stack, pull app metadata from the official Nextcloud App Store, curate an app allowlist,
download the package archives for approved apps, and validate the deployment before building
the air-gap bundle.

### Step 1.1 — Install Prerequisites

You need the following tools on the host machine before anything else.

**Docker Engine (version 24 or later)**

On Ubuntu/Debian:
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

On macOS: install [Docker Desktop](https://www.docker.com/products/docker-desktop/) from the
official site.

Verify:
```bash
docker version
docker compose version
```

> **IMPORTANT:** Docker Compose v2 (the `docker compose` subcommand, not the standalone
> `docker-compose` binary) is required. The scripts call `docker compose` without a hyphen.
> Confirm with `docker compose version` — it must report version 2.x or later.

**Git, OpenSSL, curl, Python 3**

On Ubuntu/Debian:
```bash
sudo apt-get update && sudo apt-get install -y git openssl curl python3
```

On macOS (Homebrew):
```bash
brew install git openssl curl python3
```

Minimum host resources: **4 CPU cores, 8 GB RAM, 60 GB free disk** (more when mirroring a
large allowlist of apps — each app package is typically 1–50 MB).

---

### Step 1.2 — Clone the Repository and Configure `.env`

```bash
git clone https://github.com/your-org/Nextcloud-appstore.git
cd Nextcloud-appstore
```

Copy the sample environment file and open it for editing:

```bash
cp .env.example .env
$EDITOR .env
```

Work through the file section by section. The values you must change are listed below:

| Variable | What to set | How to get it |
|---|---|---|
| `APPSTORE_DOMAIN` | Your server IP or hostname | `ip route get 1.1.1.1 \| awk '{print $7; exit}'` |
| `FILESERVER_DOMAIN` | Same IP (different port is fine) | same as above |
| `APPSTORE_API_URL` | `https://{IP_ADDRESS}/api/v1` | must end with `/api/v1` |
| `FILE_SERVER_URL` | `https://{IP_ADDRESS}:8443/apps` | base URL, no trailing slash |
| `SECRET_KEY` | 64-character random string | `tr -dc 'a-zA-Z0-9_-' < /dev/urandom \| head -c 64; echo` |
| `DB_PASSWORD` | App Store PostgreSQL password | strong random |
| `NEXTCLOUD_DB_PASSWORD` | Nextcloud PostgreSQL password | strong random |
| `NEXTCLOUD_ADMIN_USER` | Nextcloud admin username | e.g. `admin` |
| `NEXTCLOUD_ADMIN_PASSWORD` | Nextcloud admin password | strong random |
| `ADMIN_USERNAME` | App Store Django admin username | e.g. `admin` |
| `ADMIN_EMAIL` | App Store admin email | `admin@{IP_ADDRESS}` |
| `ADMIN_PASSWORD` | App Store Django admin password | strong random |
| `ALLOWED_HOSTS` | Comma-separated hosts Django accepts | `localhost,127.0.0.1,{IP_ADDRESS}` |
| `NEXTCLOUD_TRUSTED_DOMAINS` | Space-separated trusted NC domains | `{IP_ADDRESS}` |
| `GITHUB_API_TOKEN` | GitHub personal access token | https://github.com/settings/tokens |
| `NEXTCLOUD_VERSION` | Target Nextcloud version | e.g. `30.0.1` |
| `RUSTFS_ACCESS_KEY` | RustFS login name | change from default |
| `RUSTFS_SECRET_KEY` | RustFS secret (min 8 chars) | strong random |
| `RUSTFS_HOST` | IP of the RustFS server | same as `{IP_ADDRESS}` |

Generate a secure `SECRET_KEY` (do not use values containing `$` — they break variable
interpolation):
```bash
tr -dc 'a-zA-Z0-9_-' < /dev/urandom | head -c 64; echo
```

> **WARNING:** Never commit `.env` to version control. It contains passwords and secret keys.
> The `.gitignore` already excludes it. Confirm with `git status` before any commit.

> **IMPORTANT:** The `GITHUB_API_TOKEN` is required for the sync step. Without it, GitHub
> rate-limits API requests to 60 per hour and the metadata sync will fail or return
> incomplete results. Create a fine-grained personal access token with no special scopes
> at https://github.com/settings/tokens.

---

### Step 1.3 — Generate TLS Certificates

The App Store runs over HTTPS using a self-signed three-tier CA chain:

```
Root CA (10 yr) → Intermediate CA (5 yr) → Server cert (1 yr)
```

Generate certificates for your server IP:

```bash
SERVER_CN={IP_ADDRESS} \
SERVER_ALT_NAMES='IP:{IP_ADDRESS},DNS:localhost,DNS:appstore.local' \
bash k8s/generate-certs.sh
```

The script creates the following files and automatically copies them to `nginx/ssl/` so nginx
picks them up immediately without any additional steps:

| File | Location | Purpose |
|---|---|---|
| `root-ca.crt` | `k8s/certs/root-ca.crt` | Trust anchor — install on clients and in Nextcloud |
| `root-ca.key` | `k8s/certs/root-ca.key` | Root CA private key — keep secure, never share |
| `intermediate-ca.crt` | `k8s/certs/intermediate-ca.crt` | Intermediate CA |
| `server-chain.crt` | `k8s/certs/server-chain.crt` | Full chain for nginx (server + intermediate + root) |
| `server.key` | `k8s/certs/server.key` | Server private key |
| `nginx/ssl/server.crt` | auto-copied | Full chain that nginx reads |
| `nginx/ssl/server.key` | auto-copied | Private key that nginx reads |
| `nginx/ssl/root-ca.crt` | auto-copied | Root CA that nginx reads |

> **IMPORTANT:** `SERVER_ALT_NAMES` must include your actual IP address in the `IP:` form.
> If the IP is missing, clients (including Nextcloud) will reject the certificate with a TLS
> name mismatch error. Always include `IP:{IP_ADDRESS}` alongside any DNS aliases you use.

Regenerate the server certificate when it expires (after 1 year) using the same command. The
Root CA is valid for 10 years and does not need to be regenerated at the same time.

---

### Step 1.4 — Trust the Root CA on Your Workstation

Trusting the Root CA lets your browser show a green padlock and allows `curl` without `-k`.

**macOS:**
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  k8s/certs/root-ca.crt
```

**Linux (Ubuntu/Debian):**
```bash
sudo cp k8s/certs/root-ca.crt /usr/local/share/ca-certificates/appstore-root-ca.crt
sudo update-ca-certificates
```

**Linux (RHEL/CentOS/Fedora):**
```bash
sudo cp k8s/certs/root-ca.crt /etc/pki/ca-trust/source/anchors/appstore-root-ca.crt
sudo update-ca-trust extract
```

The Nextcloud container CA installation is handled automatically in Step 1.6. You do not need
to do it manually.

---

### Step 1.5 — Start the Full Stack

```bash
./scripts/appstorectl.sh online up
```

This command:
1. Runs `docker compose up -d` with `LOAD_FIXTURES=true IMPORT_TRANSLATIONS=true` to seed the
   database with category data and translation strings on first boot.
2. Polls the App Store's internal `/health/` endpoint every 3 seconds for up to two minutes.
3. Prints the service URLs when the App Store is healthy.

Monitor startup progress while waiting:
```bash
docker compose logs -f appstore    # App Store (Django migrations, fixture loading)
docker compose logs -f nextcloud   # Nextcloud first-boot installation
```

When `online up` returns, check that all services are healthy:
```bash
docker compose ps
```

Every service except `rustfs-init` (which exits normally after creating buckets) should show
`Up` or `healthy` status.

Confirm the App Store is reachable:
```bash
curl -k https://{IP_ADDRESS}/health/
# Expected output: OK
```

> **IMPORTANT:** Nextcloud performs a first-boot database installation that takes approximately
> 60 seconds after the container starts. Do not run Step 1.6 until Nextcloud finishes. Watch
> `docker compose logs -f nextcloud` until you see a message indicating Apache is running.
> Then confirm with:
> ```bash
> curl -s http://{IP_ADDRESS}:8081/status.php | python3 -m json.tool
> # Look for: "installed": true
> ```

---

### Step 1.6 — Connect Nextcloud to the App Store

Once Nextcloud has finished its first-boot installation, run:

```bash
./scripts/appstorectl.sh online setup-nextcloud
```

This command performs all of the following automatically:

1. Polls Nextcloud's `/status.php` endpoint (retries up to 40 times with 5-second intervals)
   until it returns a successful response.
2. Copies `k8s/certs/root-ca.crt` into the Nextcloud container as a trusted CA so Nextcloud
   can verify the App Store's self-signed TLS certificate.
3. Runs `update-ca-certificates` inside the Nextcloud container.
4. Sets `appstoreurl` in Nextcloud's configuration to the value of `APPSTORE_API_URL` from
   your `.env`.
5. Sets `appstoreenabled = true` in Nextcloud's configuration.
6. Sets `allow_local_remote_servers = true` so Nextcloud can reach the App Store on a
   private/loopback address. Without this flag Nextcloud's SSRF filter blocks all requests
   to `appstore.local` and `occ app:install` fails with *"Host violates local access rules"*.
7. Tests HTTPS connectivity from inside the Nextcloud container to the App Store API.
8. Automatically rolls back to the previous settings if the connectivity test fails.
9. Saves the previous `appstoreurl` and `appstoreenabled` values to
   `exports/.nc-config-backup-compose.env`.

If this command fails, see the [Troubleshooting](#troubleshooting) section.

---

### Step 1.7 — Sync App Metadata from Upstream

Pull all app metadata from the official Nextcloud App Store at `apps.nextcloud.com`:

```bash
./scripts/appstorectl.sh online sync
```

This can take 5–15 minutes depending on your connection speed. The sync performs two tasks:

1. **App metadata sync** — fetches app names, descriptions, screenshots, release versions,
   platform compatibility specifications, and download URLs for all published Nextcloud apps
   and stores them in the local PostgreSQL database.
2. **Nextcloud release sync** — populates the `NextcloudRelease` table (NC version →
   stable channel mapping) so the releases grid on each app detail page renders correctly.
   Without this step the releases table is always empty.

> **NOTE:** The sync imports metadata only — it does not download any `.tar.gz` package
> archives. Packages are downloaded in Step 1.11.

When the sync completes you will see output similar to:
```
Sync complete!
New apps imported: 312
Translations added: 312
Screenshots added: 1847
Total apps: 312
Total releases: 4821
Total screenshots: 1847

Syncing Nextcloud release metadata (versions → channels)...
[OK] Nextcloud releases synced.
```

---

### Step 1.8 — Build the App Allowlist

The allowlist file (`config/app-allowlist.txt`) controls which apps are included in air-gap
export bundles. When the file is empty, all synced apps are processed. When it contains app
IDs, only those apps are included during compatibility checks, archive downloads, and bundle
exports.

For production air-gapped deployments, curate the allowlist to include only the apps your
organization actually uses. This can reduce bundle size from hundreds of gigabytes to a few
gigabytes.

View all synced apps and their current approval status:
```bash
./scripts/appstorectl.sh online apps allowlist status
```

Add apps you want to include in the air-gap bundle (use the technical app ID, not the display
name):
```bash
./scripts/appstorectl.sh online apps allowlist add calendar
./scripts/appstorectl.sh online apps allowlist add contacts
./scripts/appstorectl.sh online apps allowlist add tasks
./scripts/appstorectl.sh online apps allowlist add deck
./scripts/appstorectl.sh online apps allowlist add groupfolders
./scripts/appstorectl.sh online apps allowlist add twofactor_totp
./scripts/appstorectl.sh online apps allowlist add user_ldap
```

You can also edit `config/app-allowlist.txt` directly — one app ID per line, lines starting
with `#` are treated as comments and ignored.

View the current allowlist:
```bash
./scripts/appstorectl.sh online apps allowlist list
```

Remove an app:
```bash
./scripts/appstorectl.sh online apps allowlist remove deck
```

> **NOTE:** App IDs are the technical identifiers from the Nextcloud App Store (for example
> `calendar`, not "Nextcloud Calendar"). The `status` command shows the correct IDs alongside
> each app's display name so you can identify them.

---

### Step 1.9 — Check Compatibility for Your Nextcloud Version

Before downloading packages, verify which allowlisted apps have a release compatible with your
target Nextcloud version:

```bash
./scripts/appstorectl.sh online apps check-compat --nc-version 30.0.1
```

The command queries the database for each approved app and finds the highest-versioned release
whose `platformVersionSpec` (for example `>=30.0.0,<31.0.0`) satisfies the target NC version
using semantic version matching.

Sample output:
```
  Total approved apps : 8
  Compatible          : 7
  Not compatible      : 1

  COMPATIBLE apps:
    calendar                            v5.0.3       >=29.0.0,<31.0.0
    contacts                            v6.0.0       >=30.0.0,<31.0.0
    tasks                               v0.15.0      >=28.0.0,<31.0.0
    ...

  NOT COMPATIBLE apps:
    legacy_app                          no release for NC 30.0.1
```

The raw JSON results are saved to `exports/compatibility_30_0_1.json` for reference by
downstream scripts.

Review incompatible apps and either remove them from the allowlist or accept that they will
not be included in the bundle.

> **NOTE:** Replace `30.0.1` with the value of `NEXTCLOUD_VERSION` set in your `.env`. If
> `NEXTCLOUD_VERSION` is set, you can omit `--nc-version` and the scripts will read it from
> the environment automatically.

---

### Step 1.10 — Generate a Compatibility Report

Generate a full CSV and JSON compatibility report covering all approved apps, their download
URLs, local archive status, checksums, and export readiness:

```bash
./scripts/appstorectl.sh online apps report --nc-version 30.0.1
```

Output files:
- `exports/COMPATIBILITY_REPORT.csv` — spreadsheet-friendly, one row per app
- `exports/COMPATIBILITY_REPORT.json` — machine-readable with full per-app detail

Each row contains these fields:

| Field | Meaning |
|---|---|
| `app_id` | Technical app identifier |
| `app_name` | Human-readable name (English) |
| `release_version` | Best compatible version number |
| `platform_spec` | NC version constraint (e.g. `>=30.0.0,<31.0.0`) |
| `nc_target` | The NC version you are targeting |
| `is_compatible` | `true` / `false` |
| `download_url` | Source URL the package will be downloaded from |
| `local_path` | Local filesystem path after download (empty until Step 1.11) |
| `checksum_sha256` | SHA-256 of the downloaded archive |
| `export_status` | `downloaded`, `missing_archive`, or `no_compatible_release` |

Review the report to confirm your allowlist covers all required apps before proceeding.

---

### Step 1.11 — Mirror Approved App Packages

Download the `.tar.gz` archives for all approved, compatible apps and rewrite the download
URLs in the database to point to the local file server instead of `apps.nextcloud.com` or
GitHub:

```bash
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.1
```

Downloaded archives are saved to `exports/app-archives/files/`. Each archive gets a
corresponding `.sha256` checksum file.

This command is idempotent — it skips archives that are already present locally. To force
re-download of everything:
```bash
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.1 --force
```

After the download completes, the database download URLs are rewritten from the public source:
```
https://github.com/.../calendar-5.0.3.tar.gz
```
to the local file server:
```
https://{IP_ADDRESS}:8443/apps/calendar-5.0.3.tar.gz
```

Confirm the file server is serving the archives:
```bash
curl -k https://{IP_ADDRESS}:8443/apps/
```

You should see a directory listing that includes the downloaded `.tar.gz` files.

---

### Step 1.12 — Validate the Commercial Deployment

Run the built-in validation suite to confirm all services are healthy:

```bash
./scripts/appstorectl.sh online test
```

The test checks:
- `postgres` container is running
- `appstore` container is running
- `nginx` container is running
- `fileserver` container is running
- App Store `/health/` endpoint responds over HTTPS
- App Store `/api/v1/` returns a valid JSON array
- File server `/apps/` is accessible

Expected output:
```
  postgres running                                    OK
  appstore running                                    OK
  nginx running                                       OK
  fileserver running                                  OK
  App Store /health/ HTTPS                            OK
  App Store API v1 returns JSON                       OK
  Fileserver /apps/ accessible                        OK

Results: 7 passed, 0 failed
```

If any check fails, see the [Troubleshooting](#troubleshooting) section before proceeding to
the bundle build step.

---

### Step 1.13 — RustFS: Bucket Initialisation, Console Access, and Auto-Upload

RustFS starts as part of the stack in Step 1.5. The `rustfs-init` one-shot service creates
the three required buckets automatically when the stack first starts:

| Bucket | Access | Purpose |
|---|---|---|
| `app-archives` | public-read | Mirrored app `.tar.gz` packages |
| `backups` | private | PostgreSQL database dumps |
| `bundles` | private | Air-gap export bundle tarballs and manifests |

**Access the RustFS web console:**

Open `http://{IP_ADDRESS}:9001/` in a browser and log in with the `RUSTFS_ACCESS_KEY` and
`RUSTFS_SECRET_KEY` from your `.env`.

**Verify or manually reinitialise buckets:**
```bash
./scripts/appstorectl.sh online backup-rustfs ls
```

This calls `init_buckets` before listing, so running it is safe and idempotent.

**Enable automatic upload after every export:**

Set `USE_RUSTFS=true` in your `.env`. After this, every call to `online export-db` and
`online export` automatically uploads the resulting files to RustFS when they finish.

**Manual uploads at any time:**
```bash
# Upload the latest DB dump to the backups bucket
./scripts/appstorectl.sh online backup-rustfs db

# Upload all app archives to the app-archives bucket
./scripts/appstorectl.sh online backup-rustfs apps

# Upload the latest bundle tarball and metadata to the bundles bucket
./scripts/appstorectl.sh online backup-rustfs bundle

# Upload everything at once (init + db + apps + bundle)
./scripts/appstorectl.sh online backup-rustfs all
```

**List bucket contents:**
```bash
./scripts/appstorectl.sh online backup-rustfs ls
./scripts/appstorectl.sh online backup-rustfs ls backups
./scripts/appstorectl.sh online backup-rustfs ls app-archives
```

> **NOTE:** The backup script uses `minio/mc` inside a disposable Docker container — no
> additional tooling is required. It communicates with RustFS through the host-mapped port
> `9000`.

---

## PHASE 2 — Build the Air-Gap Bundle

This phase remains on the commercial (internet-connected) side. The goal is to produce a
fully self-contained package that can be physically transferred to the air-gapped environment.

### Step 2.1 — Export the Database

If you have not already done so (or if you want a fresh export), dump the App Store PostgreSQL
database:

```bash
./scripts/appstorectl.sh online export-db
```

The dump is written to `exports/appstore_db_<TIMESTAMP>.sql.gz` with a corresponding
`.sha256` checksum file. If `USE_RUSTFS=true` is set, the dump is automatically uploaded to
the `backups` bucket.

---

### Step 2.2 — Build the Full Bundle

The `online export` command builds a fully self-contained bundle in a single orchestrated
sequence:

```bash
./scripts/appstorectl.sh online export --nc-version 30.0.1
```

The command runs seven steps in sequence:

1. **Compatibility report** — regenerates `COMPATIBILITY_REPORT.csv` and `.json` for the
   target NC version.
2. **Download missing archives** — fetches any approved app packages not yet downloaded
   locally.
3. **Database export** — runs `pg_dump` with `--clean --if-exists` and writes
   `appstore_db_<TIMESTAMP>.sql.gz` to `airgapped/exports/`.
4. **Save Docker images** — runs `docker save | gzip` for each required image and writes
   `.tar.gz` archives to `airgapped/images/`:
   - `nextcloudappstore__latest_<TIMESTAMP>.tar.gz`
   - `postgres__15-alpine_<TIMESTAMP>.tar.gz`
   - `nginx__alpine_<TIMESTAMP>.tar.gz`
   - `nextcloud__stable-apache_<TIMESTAMP>.tar.gz`
   - `rustfs__rustfs__latest_<TIMESTAMP>.tar.gz`
   - `minio__mc__latest_<TIMESTAMP>.tar.gz`
5. **Statistics collection** — counts approved apps, compatible apps, and exported packages.
6. **Manifest generation** — writes `VERSION.txt` and `MANIFEST.json` to `airgapped/exports/`.
7. **Checksum generation** — writes `CHECKSUMS.sha256` covering all metadata files and the
   DB dump.

Finally a bundle tarball is created at the project root:
```
nextcloud-appstore-airgap-<TIMESTAMP>.tar.gz
```

This tarball contains `airgapped/`, `k8s/`, `config/`, `nginx/`, `fileserver/`, `scripts/`,
`Dockerfile`, `docker-entrypoint.sh`, `docker-compose.yml`, and `.env.example`.

To skip re-saving Docker images (when only the database and app archives changed and images
are unchanged):
```bash
./scripts/appstorectl.sh online export --nc-version 30.0.1 --skip-images
```

If `USE_RUSTFS=true`, the bundle tarball and all metadata files are automatically uploaded to
the `bundles` bucket when the export completes.

---

### Step 2.3 — What the Bundle Contains

After a successful export, the following structure is present:

```
airgapped/
├── images/
│   ├── nextcloudappstore__latest_<TS>.tar.gz       # App Store image
│   ├── nextcloudappstore__latest_<TS>.tar.gz.sha256
│   ├── postgres__15-alpine_<TS>.tar.gz
│   ├── postgres__15-alpine_<TS>.tar.gz.sha256
│   ├── nginx__alpine_<TS>.tar.gz
│   ├── nginx__alpine_<TS>.tar.gz.sha256
│   ├── nextcloud__stable-apache_<TS>.tar.gz
│   ├── nextcloud__stable-apache_<TS>.tar.gz.sha256
│   ├── rustfs__rustfs__latest_<TS>.tar.gz
│   ├── rustfs__rustfs__latest_<TS>.tar.gz.sha256
│   ├── minio__mc__latest_<TS>.tar.gz
│   └── minio__mc__latest_<TS>.tar.gz.sha256
└── exports/
    ├── appstore_db_<TS>.sql.gz                     # Database dump
    ├── MANIFEST.json                               # Machine-readable export manifest
    ├── VERSION.txt                                 # Human-readable export manifest
    ├── COMPATIBILITY_REPORT.json                   # Per-app compatibility and status
    ├── COMPATIBILITY_REPORT.csv
    ├── ALLOWLIST.txt                               # Copy of config/app-allowlist.txt
    ├── CHECKSUMS.sha256                            # Checksums of metadata files and DB dump
    └── app-archives/
        └── files/
            ├── calendar-5.0.3.tar.gz
            ├── contacts-6.0.0.tar.gz
            └── ...
```

**`MANIFEST.json` field reference:**

| Field | Meaning |
|---|---|
| `export_timestamp` | Timestamp when the export ran |
| `appstore_version` | Branch/tag of the App Store code (`master` by default) |
| `nextcloud_version` | Target NC version passed to `--nc-version` |
| `nextcloud_major_version` | Major version only (e.g. `30`) |
| `total_approved_apps` | Number of apps on the allowlist |
| `compatible_apps` | Apps with a compatible release for the target NC version |
| `exported_packages` | Apps whose archive was successfully downloaded |
| `archive_count` | Total `.tar.gz` files in `app-archives/files/` |
| `docker_image_count` | Number of saved Docker image tarballs |
| `export_host` | Hostname of the machine that ran the export |
| `appstore_api_url` | The configured `APPSTORE_API_URL` |
| `file_server_url` | The configured `FILE_SERVER_URL` |

---

### Step 2.4 — Upload the Bundle to RustFS

Store the bundle and all supporting files in RustFS for safekeeping or retrieval from another
host:

```bash
./scripts/appstorectl.sh online backup-rustfs all
```

This uploads:
- The latest `nextcloud-appstore-airgap-*.tar.gz` to the `bundles` bucket
- `MANIFEST.json`, `VERSION.txt`, `COMPATIBILITY_REPORT.*`, `CHECKSUMS.sha256`,
  `ALLOWLIST.txt` to the `bundles` bucket
- All app archives in `airgapped/exports/app-archives/files/` to the `app-archives` bucket
- The latest DB dump to the `backups` bucket

Individual uploads:
```bash
./scripts/appstorectl.sh online backup-rustfs db
./scripts/appstorectl.sh online backup-rustfs apps
./scripts/appstorectl.sh online backup-rustfs bundle
```

---

### Step 2.5 — Verify Bundle Checksums Before Transfer

Verify file integrity before physically transferring the bundle:

```bash
# Verify each image archive against its sidecar .sha256 file
for f in airgapped/images/*.tar.gz; do
    echo -n "Checking $(basename $f)... "
    sha256sum -c "${f}.sha256" && echo OK
done

# Verify the metadata files using the CHECKSUMS.sha256 manifest
cd airgapped/exports
sha256sum -c CHECKSUMS.sha256
cd -
```

On macOS, replace `sha256sum` with `shasum -a 256`:
```bash
for f in airgapped/images/*.tar.gz; do
    shasum -a 256 -c "${f}.sha256"
done

cd airgapped/exports && shasum -a 256 -c CHECKSUMS.sha256 && cd -
```

---

## PHASE 3 — Transfer to the Air-Gapped Environment

### Step 3.1 — What to Transfer

You need to get the following to the air-gapped host. Depending on available storage capacity,
transfer either the raw directory tree or the single bundle tarball.

**Option A — Transfer the `airgapped/` directory tree** (recommended: preserves the
deployment structure directly without requiring an extract step):

Transfer these directories from the project root:
```
airgapped/          ← images, exports, docker-compose files
nginx/              ← nginx.conf and ssl/ directory with TLS certs
fileserver/         ← fileserver nginx.conf
k8s/certs/          ← root-ca.crt needed by configure-nextcloud
k8s/generate-certs.sh  ← needed only if regenerating certs on the air-gap host
config/             ← app-allowlist.txt
scripts/            ← appstorectl.sh and all helper scripts
docker-compose.yml  ← referenced by some appstorectl commands
.env.example        ← template for the air-gap .env
```

**Option B — Transfer the single bundle tarball** (one large file, simpler for USB transfer):

Transfer `nextcloud-appstore-airgap-<TIMESTAMP>.tar.gz` and all image tarballs from
`airgapped/images/` to the air-gapped host. Then extract the bundle on the air-gapped host:
```bash
tar -xzf nextcloud-appstore-airgap-<TIMESTAMP>.tar.gz
```

The image tarballs are not included inside the bundle tarball and must be transferred
separately.

---

### Step 3.2 — Transfer Methods

**USB drive or external storage:**
```bash
# On the commercial host — copy everything to a USB drive mounted at /media/usb
DEST=/media/usb/nextcloud-appstore

mkdir -p "${DEST}"
cp -r airgapped/ "${DEST}/"
cp -r nginx/ "${DEST}/"
cp -r fileserver/ "${DEST}/"
cp -r k8s/ "${DEST}/"
cp -r config/ "${DEST}/"
cp -r scripts/ "${DEST}/"
cp docker-compose.yml .env.example "${DEST}/"
```

**Secure file transfer over SSH** (if a one-time-use secure channel is permitted):
```bash
# From the commercial host
scp -r airgapped/ operator@{AIRGAP_IP}:/opt/nextcloud-appstore/
scp -r nginx/ k8s/ config/ scripts/ fileserver/ \
    docker-compose.yml .env.example \
    operator@{AIRGAP_IP}:/opt/nextcloud-appstore/
```

---

### Step 3.3 — Verify Checksums After Transfer

On the air-gapped host, change into the deployment directory and verify that all files
transferred without corruption:

```bash
cd /opt/nextcloud-appstore  # or wherever you placed the files

# Verify Docker image archives
for f in airgapped/images/*.tar.gz; do
    if [ -f "${f}.sha256" ]; then
        sha256sum -c "${f}.sha256" || echo "CHECKSUM FAILED: $f"
    fi
done

# Verify metadata files and DB dump
cd airgapped/exports
sha256sum -c CHECKSUMS.sha256
cd -
```

If any checksum fails, re-transfer the affected file before proceeding. A failed checksum
means the file was corrupted or truncated in transit.

---

## PHASE 4 — Air-Gapped Docker Compose Deployment

No internet access is required for any step in this phase. All Docker images are loaded from
the local filesystem.

### Step 4.1 — Prerequisites on the Air-Gapped Host

Install Docker Engine on the air-gapped host before any other step. If the host has never had
internet access, use an offline installer.

**Offline installation on Ubuntu/Debian** — download the `.deb` packages on an
internet-connected machine of the same OS and CPU architecture, transfer them, then install:
```bash
# On the internet-connected machine (Ubuntu 22.04 x86_64 example)
apt-get download \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Transfer .deb files to air-gapped host, then on the air-gapped host:
sudo dpkg -i *.deb
```

**Offline installation on RHEL/Rocky Linux** — download the `.rpm` packages from
https://download.docker.com/linux/rhel/docker-ce.repo and transfer similarly.

After installation, verify:
```bash
docker version
docker compose version
```

Also confirm these standard utilities are available (present on virtually all Linux systems):
- `bash` 4.0 or later
- `gzip`
- `tar`
- `curl`
- `python3`

---

### Step 4.2 — Configure the Air-Gapped `.env`

The `appstorectl.sh` script reads environment variables from the project root `.env` file.
The air-gapped compose stack additionally reads from
`airgapped/docker-compose/.env.airgapped.example` (passed via `--env-file`).

**Configure the air-gapped compose env file:**

The current deploy script passes `airgapped/docker-compose/.env.airgapped.example` as the
`--env-file`. Edit this file directly, or copy it to `.env` in the same directory and update
the script's `--env-file` path:
```bash
cp airgapped/docker-compose/.env.airgapped.example airgapped/docker-compose/.env
$EDITOR airgapped/docker-compose/.env
```

Set these values in `airgapped/docker-compose/.env`:
```bash
# 64-character random string (generate with: tr -dc 'a-zA-Z0-9_-' < /dev/urandom | head -c 64; echo)
SECRET_KEY=<64-char random string>

DB_PASSWORD=<strong password — must match the value in the exported DB dump>
NEXTCLOUD_DB_PASSWORD=<strong password>

ALLOWED_HOSTS=localhost,127.0.0.1,{IP_ADDRESS}
APPSTORE_DOMAIN={IP_ADDRESS}

NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=<strong password>
NEXTCLOUD_TRUSTED_DOMAINS={IP_ADDRESS}
```

**Configure the project root `.env`:**

The `appstorectl.sh` script reads this file for `APPSTORE_API_URL`, `FILE_SERVER_URL`,
`RUSTFS_*` variables, and Nextcloud integration settings. Copy `.env.example` and update it:
```bash
cp .env.example .env
$EDITOR .env
```

For the air-gapped environment, set these URL variables to point to the air-gapped host IP
and the air-gapped stack's ports:
```bash
APPSTORE_DOMAIN={IP_ADDRESS}
FILESERVER_DOMAIN={IP_ADDRESS}
APPSTORE_API_URL=https://{IP_ADDRESS}:30443/api/v1
FILE_SERVER_URL=https://{IP_ADDRESS}:30444/apps
ALLOWED_HOSTS=localhost,127.0.0.1,{IP_ADDRESS}
NEXTCLOUD_CONTAINER_NAME=nextcloud
NEXTCLOUD_RUNTIME=compose
DB_PASSWORD=<must match the DB dump's password>
SECRET_KEY=<same as above>
RUSTFS_HOST={IP_ADDRESS}
RUSTFS_ACCESS_KEY=<your chosen access key>
RUSTFS_SECRET_KEY=<your chosen secret key>
```

> **IMPORTANT:** `DB_PASSWORD` in the air-gapped `.env` must exactly match the password that
> was used when the database dump was created on the commercial side. The dump's SQL contains
> data but not the PostgreSQL user password; the password is set by the `POSTGRES_PASSWORD`
> environment variable when PostgreSQL first initialises. Set it to the same value you used
> on the commercial side.

> **IMPORTANT:** `APPSTORE_API_URL` is the value written into Nextcloud's `config.php` by
> `configure-nextcloud`. It must be reachable from inside the Nextcloud container. Inside the
> Docker network, nginx listens on port 443 (the internal port) with the network alias
> `appstore.local`. You can use either `https://appstore.local/api/v1` (internal alias, no
> port) or `https://{IP_ADDRESS}:30443/api/v1` (host-mapped port, reachable from anywhere).

---

### Step 4.3 — Copy TLS Certificates

The nginx service expects TLS certificates at `nginx/ssl/server.crt`, `nginx/ssl/server.key`,
and `nginx/ssl/root-ca.crt`.

**Option A — Use the certificates transferred from the commercial host** (recommended when
the air-gapped server uses the same IP address):

If you transferred the `nginx/ssl/` directory as described in Phase 3, the certs are already
in place. Verify:
```bash
ls -la nginx/ssl/
# Expected: server.crt  server.key  root-ca.crt
```

**Option B — Regenerate certificates for the air-gapped host's IP** (required when the
air-gapped server has a different IP address from the commercial host):
```bash
SERVER_CN={IP_ADDRESS} \
SERVER_ALT_NAMES='IP:{IP_ADDRESS},DNS:localhost,DNS:appstore.local' \
bash k8s/generate-certs.sh
```

This requires `openssl` to be installed. The script copies certs to `nginx/ssl/`
automatically.

Trust the new Root CA on the air-gapped host:
```bash
# Ubuntu/Debian
sudo cp k8s/certs/root-ca.crt /usr/local/share/ca-certificates/appstore-root-ca.crt
sudo update-ca-certificates

# RHEL/Rocky
sudo cp k8s/certs/root-ca.crt /etc/pki/ca-trust/source/anchors/appstore-root-ca.crt
sudo update-ca-trust extract
```

---

### Step 4.4 — Load Docker Images

Load all Docker image tarballs from `airgapped/images/` into the local Docker daemon:

```bash
./scripts/appstorectl.sh airgap load-images
```

The script iterates over every `.tar.gz` file in `airgapped/images/`, verifies the SHA-256
checksum against the sidecar `.sha256` file (warns on mismatch, does not abort), then pipes
each archive through `gunzip | docker load`.

Expected output:
```
==============================================
Loading Air-Gapped Docker Images
==============================================
Images directory: airgapped/images

Verifying checksum: nextcloudappstore__latest_20241201_120000.tar.gz ...
Loading: nextcloudappstore__latest_20241201_120000.tar.gz ...
  OK
Verifying checksum: postgres__15-alpine_20241201_120000.tar.gz ...
Loading: postgres__15-alpine_20241201_120000.tar.gz ...
  OK
...
==============================================
Load complete: 6 loaded, 0 failed
==============================================
```

Verify the images are available in the local Docker daemon:
```bash
docker images | grep -E "(nextcloudappstore|postgres|nginx|nextcloud|rustfs|mc)"
```

You should see all six images: `nextcloudappstore:latest`, `postgres:15-alpine`,
`nginx:alpine`, `nextcloud:stable-apache`, `rustfs/rustfs:latest`, `minio/mc:latest`.

> **IMPORTANT:** If any image fails to load, do not proceed to deployment. Re-transfer the
> affected archive, verify its checksum, and re-run `airgap load-images`.

---

### Step 4.5 — Deploy the Full Air-Gapped Stack

```bash
./scripts/appstorectl.sh airgap deploy compose
```

This calls `airgapped/scripts/deploy-compose-airgap.sh`, which:

1. Verifies that `nextcloudappstore:latest` is present in the local Docker daemon (fails with
   a clear error if missing).
2. Verifies that `nginx/ssl/server.crt` exists (fails if certs are missing).
3. Finds the most recent DB dump in `airgapped/exports/` and creates the symlink
   `airgapped/exports/appstore_db_latest.sql.gz` pointing to it.
4. Runs `docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml up -d`.
5. Waits up to 100 seconds for the App Store container to report a healthy status.

> **NOTE:** Every service in the air-gapped compose file carries `pull_policy: never`. Docker
> will not attempt to pull any image from a registry. If an image is missing from the local
> daemon, the service fails with `No such image` — not a network error. Return to Step 4.4 to
> load missing images.

Watch startup logs:
```bash
docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml logs -f
```

Confirm the App Store is healthy:
```bash
curl -k https://{IP_ADDRESS}:30443/health/
# Expected: OK
```

Confirm the file server is serving archives:
```bash
curl -k https://{IP_ADDRESS}:30444/apps/
```

---

### Step 4.6 — What the `db-import` Service Does Automatically

The `db-import` service is a one-shot PostgreSQL container that imports the App Store database
on first deployment. Its behavior:

1. Mounts `airgapped/exports/` read-only as `/exports` inside the container.
2. Looks for `/exports/appstore_db_latest.sql.gz` (the symlink created in Step 4.5).
3. If the file is found, runs `gunzip -c | psql -h postgres -U nextcloudappstore -d nextcloudappstore`.
4. Exits with code 0 whether or not the dump was found — the stack starts even without a dump,
   with an empty App Store database.
5. Has `restart: "no"` so it will not restart automatically after it exits.

The `db-import` service runs concurrently with `appstore`. Django's startup migrations run
first to ensure the schema exists; the import overlays data on top of the migrated schema.
The dump is generated with `--clean --if-exists`, which drops and recreates tables before
inserting data, making the import idempotent.

Check import status:
```bash
docker logs appstore-db-import
```

A successful import shows:
```
Importing App Store database from /exports/appstore_db_latest.sql.gz ...
Import complete.
```

---

### Step 4.7 — Initialise RustFS Buckets

The `rustfs-init` service in the air-gapped compose file runs automatically when the stack
starts and creates the three required buckets. Confirm it ran successfully:

```bash
docker logs appstore-rustfs-init
```

Expected output:
```
RustFS buckets ready.
```

If you need to reinitialise buckets manually (for example after deleting and recreating the
`rustfs_data` volume):
```bash
./scripts/backup-to-rustfs.sh init
```

---

### Step 4.8 — Connect Nextcloud to the Local App Store

```bash
./scripts/appstorectl.sh airgap configure-nextcloud
```

With the default `NEXTCLOUD_RUNTIME=compose` setting, this calls
`airgapped/scripts/configure-nextcloud-compose.sh`, which:

1. Verifies the Nextcloud container named in `NEXTCLOUD_CONTAINER_NAME` (default: `nextcloud`)
   is running.
2. Saves the current `appstoreurl` and `appstoreenabled` values to
   `exports/.nc-config-backup-compose.env`.
3. Copies `k8s/certs/root-ca.crt` into the Nextcloud container and runs
   `update-ca-certificates` so Nextcloud trusts the local App Store's TLS certificate.
4. Sets `appstoreenabled = true` via `php occ config:system:set`.
5. Sets `appstoreurl` to the value of `APPSTORE_API_URL` from `.env` via
   `php occ config:system:set`.
6. Tests HTTPS connectivity from inside the Nextcloud container to the App Store API endpoint.
7. Rolls back to the saved values if the connectivity test fails, then exits with an error.

> **IMPORTANT:** Wait for Nextcloud to finish its first-boot installation before running this
> step. If the Nextcloud container just started for the first time, wait approximately
> 60–90 seconds. Check readiness before proceeding:
> ```bash
> curl -s http://{IP_ADDRESS}:8081/status.php | python3 -m json.tool
> # Look for: "installed": true
> ```

Confirm the configuration was applied:
```bash
docker exec -u www-data nextcloud php occ config:system:get appstoreurl
docker exec -u www-data nextcloud php occ config:system:get appstoreenabled
```

If Nextcloud is running on an SSH-accessible server or in Kubernetes, set the runtime
variable in `.env` before running configure:
```bash
# For Kubernetes Nextcloud
NEXTCLOUD_RUNTIME=k8s
./scripts/appstorectl.sh airgap configure-nextcloud

# For SSH/bare-metal Nextcloud
NEXTCLOUD_RUNTIME=ssh
./scripts/appstorectl.sh airgap configure-nextcloud
```

---

### Step 4.9 — Validate the Air-Gapped Deployment

```bash
./scripts/appstorectl.sh airgap test compose
```

This runs a comprehensive validation suite covering:

**Service health:**
- `postgres` container running
- `appstore` container running
- `nginx` container running
- `fileserver` container running

**HTTP endpoints:**
- `https://localhost:30443/health/` returns 200
- `https://localhost:30443/api/v1/` returns valid JSON
- `https://localhost:30444/apps/` is accessible

**Database integrity:**
- `app_release` table is populated (not empty)
- Zero download URLs in the database point to `apps.nextcloud.com` or GitHub (all must have
  been rewritten to the local file server)
- At least one release URL references the local file server

**Local app archive availability:**
- A sample app package from the database is downloadable from the local file server

**Nextcloud integration** (when `NEXTCLOUD_CONTAINER_NAME` is set in `.env`):
- Nextcloud container is running
- `appstoreurl` points to the local App Store API URL
- `appstoreenabled` is `true`
- Nextcloud can list apps via `occ app:list`

Expected output on a healthy deployment:
```
================================================================
Air-Gapped Deployment Validation (compose)
================================================================

── Service Health ──────────────────────────────────────────────
  postgres running                                        PASS
  appstore running                                        PASS
  nginx running                                           PASS
  fileserver running                                      PASS

── HTTP Endpoints ──────────────────────────────────────────────
  App Store /health/ (HTTPS)                             PASS
  App Store /api/v1/ returns JSON array                  PASS
  Fileserver /apps/ listing reachable                    PASS

── Database Integrity ──────────────────────────────────────────
  app_release table populated                            PASS
  all download URLs rewritten to local fileserver...     PASS (0 public URLs found)
  at least one release URL points to local fileserver... PASS (312 local URLs)

── Local App Archive Availability ──────────────────────────────
  sample app package downloadable from fileserver        PASS
                              apps in database...         312 apps

── Nextcloud Integration ────────────────────────────────────────
  Nextcloud container running                            PASS
  Nextcloud appstoreurl points to local App Store        PASS
  Nextcloud appstoreenabled = true                       PASS
  Nextcloud can list apps from local store               PASS

================================================================
Results: 15 passed  |  0 failed  |  0 warnings
================================================================
```

---

### Step 4.10 — Access the Deployed Air-Gapped System

| Service | URL | Credentials |
|---|---|---|
| App Store web UI | `https://{IP_ADDRESS}:30443/` | `ADMIN_USERNAME` / `ADMIN_PASSWORD` |
| App Store admin panel | `https://{IP_ADDRESS}:30443/admin/` | `ADMIN_USERNAME` / `ADMIN_PASSWORD` |
| App Store API | `https://{IP_ADDRESS}:30443/api/v1/` | public |
| App Store health check | `https://{IP_ADDRESS}:30443/health/` | public |
| File server | `https://{IP_ADDRESS}:30444/apps/` | public |
| Nextcloud | `http://{IP_ADDRESS}:8081/` | `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` |
| RustFS S3 API | `http://{IP_ADDRESS}:9000/` | `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` |
| RustFS web console | `http://{IP_ADDRESS}:9001/` | `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` |

Log in to Nextcloud with the admin credentials from your `.env`. Navigate to **Apps** in the
Nextcloud top-right menu — the app list should be populated from the local App Store rather
than `apps.nextcloud.com`.

---

## PHASE 5 — Update Cycle

Repeat this cycle on whatever schedule aligns with your organization's change management
process. A common cadence is monthly or whenever a new Nextcloud minor or major version is
released.

### Step 5.1 — On the Commercial Side: Re-Sync and Re-Export

On the internet-connected machine, bring up the commercial stack if it is not running:
```bash
./scripts/appstorectl.sh online up
```

Pull the latest app metadata from the upstream App Store:
```bash
./scripts/appstorectl.sh online sync
```

Review and update the allowlist if you need to add or remove apps:
```bash
./scripts/appstorectl.sh online apps allowlist status
./scripts/appstorectl.sh online apps allowlist add new_app_id
./scripts/appstorectl.sh online apps allowlist remove old_app_id
```

Check compatibility for the new or updated target NC version:
```bash
./scripts/appstorectl.sh online apps check-compat --nc-version 30.0.2
```

Download any new or updated app packages:
```bash
./scripts/appstorectl.sh online apps mirror-approved --nc-version 30.0.2
```

Build the new export bundle. If Docker images did not change (no new App Store build), skip
re-saving them to significantly reduce export time and bundle size:
```bash
./scripts/appstorectl.sh online export --nc-version 30.0.2 --skip-images
```

If the `appstore` image was rebuilt (new code deployed), omit `--skip-images`:
```bash
./scripts/appstorectl.sh online export --nc-version 30.0.2
```

Upload to RustFS for archiving:
```bash
./scripts/appstorectl.sh online backup-rustfs all
```

---

### Step 5.2 — Transfer the New Bundle

Transfer the new bundle to the air-gapped environment using the same method as Phase 3.

If images were not regenerated (`--skip-images`), you only need to transfer:
- `airgapped/exports/appstore_db_<NEW_TIMESTAMP>.sql.gz`
- `airgapped/exports/MANIFEST.json` and other metadata files
- Any new or updated files in `airgapped/exports/app-archives/files/`

If images were regenerated, transfer the complete updated `airgapped/images/` directory.

Always verify checksums after transfer:
```bash
sha256sum -c airgapped/exports/CHECKSUMS.sha256
for f in airgapped/images/*.tar.gz; do
    [ -f "${f}.sha256" ] && sha256sum -c "${f}.sha256"
done
```

---

### Step 5.3 — On the Air-Gapped Side: Load New Images and Import New Database

**If Docker images were updated**, load the new image tarballs:
```bash
./scripts/appstorectl.sh airgap load-images
```

Loading a new tarball with the same tag (e.g., `nextcloudappstore:latest`) replaces the old
image. Clean up dangling images afterwards:
```bash
docker image prune -f
```

**Stop the running stack** (preserving data volumes):
```bash
docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml down
```

> **WARNING:** Do not use `down -v`. That flag deletes all named volumes including
> `postgres_data` and `nc_data`, destroying all data. Always use `down` without `-v`.

**Update the DB dump symlink** so `db-import` picks up the new dump when the stack restarts.
The deploy script handles this automatically when you call `airgap deploy compose` — it finds
the most recent `.sql.gz` file and creates or updates the symlink. You can also do it
manually:
```bash
cd airgapped/exports
ln -sf appstore_db_<NEW_TIMESTAMP>.sql.gz appstore_db_latest.sql.gz
cd -
```

**Restart the stack:**
```bash
./scripts/appstorectl.sh airgap deploy compose
```

The `db-import` one-shot service runs again and imports the new dump. Because the dump
includes `--clean --if-exists`, it drops and recreates all App Store tables, so no manual
cleanup of the old data is needed.

**Validate the updated deployment:**
```bash
./scripts/appstorectl.sh airgap test compose
```

**Reconnect Nextcloud** if needed (required if `APPSTORE_API_URL` changed, or if the
Nextcloud container was recreated):
```bash
./scripts/appstorectl.sh airgap configure-nextcloud
```

---

## Troubleshooting

### App Store container fails to start

**Symptom:** `docker compose ps` shows `appstore` in `Exit` or `Error` state.

**Check the logs:**
```bash
docker compose logs appstore
docker logs appstore-app
```

**Common causes:**

`SECRET_KEY` contains a `$` character, which breaks shell variable interpolation. Regenerate:
```bash
tr -dc 'a-zA-Z0-9_-' < /dev/urandom | head -c 64; echo
```

`postgres` is not yet healthy when `appstore` tries to connect. The compose file uses
`condition: service_healthy` for the dependency, but on heavily loaded hosts postgres
initialization can take longer than expected. Restart the App Store service:
```bash
docker compose restart appstore
```

`ALLOWED_HOSTS` does not include the container hostname. Add `appstore` and the host IP:
```bash
ALLOWED_HOSTS=localhost,127.0.0.1,{IP_ADDRESS},appstore
```

---

### TLS certificate errors in the browser

**Symptom:** Browser shows "Your connection is not private" or a certificate warning.

**Root CA not trusted on your workstation.** Re-run the trust step for your OS from
Step 1.4. On macOS you may also need to restart the browser after adding the cert.

**Certificate does not include your IP in the Subject Alternative Names.** Regenerate with
the correct `SERVER_ALT_NAMES`:
```bash
SERVER_CN={IP_ADDRESS} \
SERVER_ALT_NAMES='IP:{IP_ADDRESS},DNS:localhost,DNS:appstore.local' \
bash k8s/generate-certs.sh
docker compose restart nginx
```

**Using `localhost` in the browser but the cert was issued for an IP only.** Add
`DNS:localhost` to `SERVER_ALT_NAMES` and regenerate.

---

### Nextcloud cannot reach the App Store

**Symptom:** `online setup-nextcloud` or `airgap configure-nextcloud` fails with a
connectivity test failure.

Debug from inside the Nextcloud container:
```bash
docker exec nextcloud curl -v https://appstore.local/api/v1/
docker exec nextcloud curl -v https://{IP_ADDRESS}/api/v1/
```

**CA cert not installed.** The configure script installs it automatically, but if
`k8s/certs/root-ca.crt` was missing when the script ran, the cert was skipped. Generate
certs first and re-run:
```bash
bash k8s/generate-certs.sh
./scripts/appstorectl.sh online setup-nextcloud
```

**Wrong `APPSTORE_API_URL`.** The URL must be reachable from inside the Nextcloud container
on the shared Docker network. The nginx container has network aliases `appstore.local` and
the value of `APPSTORE_DOMAIN`. Both work without specifying a port inside the network.
On the air-gapped stack, nginx internally listens on port 443 (not 30443 — that is only the
host-mapped port):
```bash
# Inside the Docker network, use:
APPSTORE_API_URL=https://appstore.local/api/v1
# NOT:
APPSTORE_API_URL=https://{IP_ADDRESS}:30443/api/v1  # (works from host, not from inside NC container)
```

**App Store not running.** Verify:
```bash
docker compose ps appstore
```

---

### DB dump not found by `db-import` in air-gapped deployment

**Symptom:** `docker logs appstore-db-import` shows "No DB dump found".

Check whether the symlink exists and points to a real file:
```bash
ls -la airgapped/exports/appstore_db_latest.sql.gz
```

If the symlink is missing or broken, create it manually:
```bash
DUMP=$(find airgapped/exports -maxdepth 1 -name 'appstore_db_*.sql.gz' | sort -r | head -1)
ln -sf "$(basename "${DUMP}")" airgapped/exports/appstore_db_latest.sql.gz
```

Then restart the db-import service:
```bash
docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml \
  up -d --force-recreate db-import
docker logs -f appstore-db-import
```

Alternatively, import the dump manually:
```bash
DUMP=$(find airgapped/exports -maxdepth 1 -name 'appstore_db_*.sql.gz' | sort -r | head -1)
gunzip -c "${DUMP}" | docker exec -i appstore-postgres \
  psql -U nextcloudappstore -d nextcloudappstore --quiet
```

---

### Docker images fail to load in air-gapped environment

**Symptom:** `airgap load-images` reports `FAILED` for one or more images.

**Checksum mismatch warning:**
```
WARNING: checksum mismatch for postgres__15-alpine_20241201_120000.tar.gz
```
The archive was corrupted during transfer. Re-transfer the file from the commercial host and
verify before re-running:
```bash
sha256sum airgapped/images/postgres__15-alpine_*.tar.gz
cat airgapped/images/postgres__15-alpine_*.tar.gz.sha256
```

**`gunzip` decompression error:** The file was truncated. Re-transfer from the commercial host.

**Insufficient disk space.** Docker images can be several GB each. Check free space:
```bash
df -h /var/lib/docker
```

---

### RustFS not reachable

**Symptom:** `backup-to-rustfs.sh` or `online backup-rustfs` reports "RustFS not reachable".

Check the RustFS container:
```bash
docker inspect appstore-rustfs --format='{{.State.Status}}'
docker logs appstore-rustfs
```

Check the health endpoint directly:
```bash
curl -fs http://{IP_ADDRESS}:9000/minio/health/live && echo OK
```

`RUSTFS_HOST` is set to `localhost` in `.env`. The backup script connects through the
publicly-mapped host port, so it needs the actual host IP:
```bash
RUSTFS_HOST={IP_ADDRESS}
```

RustFS volume is full. Check usage:
```bash
docker exec appstore-rustfs df -h /data
```

---

### App Store API returns an empty array after DB import

**Symptom:** `curl -k https://{IP_ADDRESS}:30443/api/v1/` returns `[]`.

The DB import has not completed yet, or the dump file was empty:
```bash
docker logs appstore-db-import
docker exec appstore-postgres psql -U nextcloudappstore nextcloudappstore \
  -c "SELECT count(*) FROM nextcloudappstore_core_app;"
```

If the count is 0, trigger a manual import:
```bash
DUMP=$(find airgapped/exports -maxdepth 1 -name 'appstore_db_*.sql.gz' | sort -r | head -1)
gunzip -c "${DUMP}" | docker exec -i appstore-postgres \
  psql -U nextcloudappstore nextcloudappstore --quiet
```

---

### Nextcloud Apps page shows "Could not connect to the App Store"

`appstoreenabled` may not have been set. Check and set it:
```bash
docker exec -u www-data nextcloud php occ config:system:get appstoreenabled
docker exec -u www-data nextcloud php occ \
  config:system:set appstoreenabled --value=true --type=boolean
```

Check the configured URL:
```bash
docker exec -u www-data nextcloud php occ config:system:get appstoreurl
```

If the URL is wrong or empty, re-run configure:
```bash
./scripts/appstorectl.sh online setup-nextcloud    # commercial
./scripts/appstorectl.sh airgap configure-nextcloud  # air-gapped
```

---

### Sync fails with rate limit errors from GitHub

**Symptom:** The sync script reports HTTP 403 or 429 errors.

Create a new fine-grained personal access token (no special scopes needed for public
repositories) at https://github.com/settings/tokens, update `.env`:
```bash
GITHUB_API_TOKEN=ghp_your_new_token_here
```

Then re-run:
```bash
./scripts/appstorectl.sh online sync
```

---

### Nextcloud still shows old app versions after DB update

Nextcloud caches the App Store app list. Clear the cache:
```bash
docker exec -u www-data nextcloud php occ maintenance:mode --on
docker exec -u www-data nextcloud php occ files:cleanup
docker exec -u www-data nextcloud php occ maintenance:mode --off
```

Or wait — Nextcloud refreshes its app list on a built-in schedule (typically once per hour).

---

### Services fail with "No such image" in air-gapped mode

All services in the air-gapped compose file carry `pull_policy: never`. If an image is
missing from the local Docker daemon, the service fails immediately with a "No such image"
error rather than attempting a network pull.

Identify which image is missing from the error message, then load it:
```bash
docker images   # shows what is currently loaded
gunzip -c airgapped/images/<image_name>.tar.gz | docker load
```

Or re-run the full load step:
```bash
./scripts/appstorectl.sh airgap load-images
```

---

### Useful Diagnostic Commands

```bash
# Container status for commercial stack
docker compose ps

# Container status for air-gapped stack
docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml ps

# Follow logs for a specific service
docker compose logs -f appstore
docker compose logs -f nextcloud

# Open a shell in a container
docker exec -it appstore-app bash
docker exec -it appstore-postgres bash

# Run an occ command in Nextcloud
docker exec -u www-data -it nextcloud php occ list

# Query the App Store database
docker exec -it appstore-postgres \
  psql -U nextcloudappstore nextcloudappstore \
  -c "SELECT count(*) FROM nextcloudappstore_core_app;"

# Check RustFS bucket contents
./scripts/appstorectl.sh online backup-rustfs ls
./scripts/appstorectl.sh online backup-rustfs ls backups
```

### Stack Teardown (use with care)

```bash
# Stop all services — keeps data volumes intact
docker compose down

# Stop all air-gapped services — keeps data volumes intact
docker compose -f airgapped/docker-compose/docker-compose.airgapped.yml down
```

> **WARNING:** Adding `-v` to the `down` command deletes all named Docker volumes including
> `postgres_data` (App Store database), `postgres_nc_data` (Nextcloud database), `nc_data`
> (Nextcloud files), and `rustfs_data` (object store). This is irreversible. Only use
> `down -v` when you intend to completely wipe the deployment and start over from scratch.

---

*For Kubernetes deployment instructions, refer to the manifests under `k8s/` (commercial) and
`airgapped/k8s/` (air-gapped) and the corresponding sections in `RUN.md`.*
