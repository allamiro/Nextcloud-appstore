#!/usr/bin/env bash
# =============================================================================
# appstorectl.sh — Nextcloud App Store Deployment Toolkit
# =============================================================================
#
# Usage:
#   ./scripts/appstorectl.sh <stage> <action> [target] [options]
#
# Stages:
#   online   Online/staging workflow (internet required)
#   package  Build air-gapped deployment package
#   airgap   Air-gapped deployment workflow (offline)
#
# Run without arguments to see full usage.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
AIRGAP_DIR="${PROJECT_DIR}/airgapped"

# Load .env if present
if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "${PROJECT_DIR}/.env"
    set +a
fi

# ── Defaults ──────────────────────────────────────────────────────────────────
APPSTORE_DOMAIN="${APPSTORE_DOMAIN:-appstore.local}"
FILESERVER_DOMAIN="${FILESERVER_DOMAIN:-files.local}"
APPSTORE_API_URL="${APPSTORE_API_URL:-https://${APPSTORE_DOMAIN}/api/v1}"
FILE_SERVER_URL="${FILE_SERVER_URL:-https://${FILESERVER_DOMAIN}/apps}"
K8S_NAMESPACE="${K8S_NAMESPACE:-nextcloud-appstore}"
NEXTCLOUD_MODE="${NEXTCLOUD_MODE:-external}"
NEXTCLOUD_RUNTIME="${NEXTCLOUD_RUNTIME:-compose}"
AIRGAP_IMAGE_DIR="${AIRGAP_IMAGE_DIR:-${AIRGAP_DIR}/images}"
AIRGAP_EXPORT_DIR="${AIRGAP_EXPORT_DIR:-${AIRGAP_DIR}/exports}"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }
separator() { echo ""; echo "══════════════════════════════════════════════════"; }

require_cmd() {
    command -v "$1" &>/dev/null || error "'$1' is required but not installed."
}

# ── macOS bind-mount staging ───────────────────────────────────────────────────
# Docker Desktop on macOS cannot bind-mount paths inside ~/Desktop (macOS TCC).
# When running on macOS, stage all host-path config files to ~/.appstore-runtime/
# so Docker can access them.
RUNTIME_DIR="${HOME}/.appstore-runtime"

_on_macos() { [[ "$(uname)" == "Darwin" ]]; }

_stage_runtime_configs() {
    info "Staging host configs to ${RUNTIME_DIR} (macOS Docker Desktop workaround)..."
    mkdir -p \
        "${RUNTIME_DIR}/nginx/ssl" \
        "${RUNTIME_DIR}/fileserver" \
        "${RUNTIME_DIR}/config" \
        "${RUNTIME_DIR}/k8s/certs" \
        "${RUNTIME_DIR}/exports/app-archives/files"

    cp "${PROJECT_DIR}/nginx/nginx.conf"      "${RUNTIME_DIR}/nginx/"
    cp "${PROJECT_DIR}/fileserver/nginx.conf"  "${RUNTIME_DIR}/fileserver/"

    if ls "${PROJECT_DIR}/nginx/ssl/"*.{crt,key} &>/dev/null; then
        cp "${PROJECT_DIR}/nginx/ssl/"*.crt "${RUNTIME_DIR}/nginx/ssl/" 2>/dev/null || true
        cp "${PROJECT_DIR}/nginx/ssl/"*.key "${RUNTIME_DIR}/nginx/ssl/" 2>/dev/null || true
    fi

    cp "${PROJECT_DIR}/config/"*              "${RUNTIME_DIR}/config/"    2>/dev/null || true
    cp "${PROJECT_DIR}/k8s/certs/"*           "${RUNTIME_DIR}/k8s/certs/" 2>/dev/null || true

    if command -v rsync &>/dev/null; then
        rsync -a --delete \
            "${PROJECT_DIR}/exports/app-archives/files/" \
            "${RUNTIME_DIR}/exports/app-archives/files/" 2>/dev/null || true
    fi

    info "Config staging complete → ${RUNTIME_DIR}"
}

# Returns the compose -f flags appropriate for the current platform.
# On macOS: base file + macOS overlay; on Linux: base file only.
_compose_files() {
    local base="-f ${PROJECT_DIR}/docker-compose.yml"
    if _on_macos; then
        echo "${base} -f ${PROJECT_DIR}/docker-compose.macos.yml"
    else
        echo "${base}"
    fi
}

require_running_appstore() {
    # shellcheck disable=SC2046
    docker compose $(_compose_files) ps appstore \
        2>/dev/null | grep -q "Up" \
        || error "App Store container is not running. Start with: $0 online up"
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF

Nextcloud App Store Deployment Toolkit
Usage: $(basename "$0") <stage> <action> [target] [options]

ONLINE (internet required) — first-time workflow:
  online up
      Start the full stack: App Store + Nextcloud + databases + nginx + fileserver.
      Nextcloud auto-installs on first boot (takes ~1 min after the container starts).

  online setup-nextcloud
      Install the CA certificate inside the Nextcloud container and configure it
      to use the local App Store. Run this once after 'online up'.

  online audit
      Show repo structure, image status, and environment summary.

  online sync [--limit N]
      Sync all app metadata from the official Nextcloud App Store.

  online mirror
      Download all app .tar.gz archives and rewrite DB URLs to local fileserver.

  online apps allowlist <list|add|remove|status> [app_id]
      Manage the app allowlist (config/app-allowlist.txt).

  online apps check-compat [--nc-version X.Y.Z]
      Check approved apps for compatibility with the target Nextcloud version.

  online apps report [--nc-version X.Y.Z]
      Generate COMPATIBILITY_REPORT.csv / .json in exports/.

  online apps mirror-approved [--nc-version X.Y.Z] [--force]
      Download only approved, compatible app packages with checksums.

  online export [--nc-version X.Y.Z] [--skip-images]
      Build the complete air-gapped bundle: images + DB + apps + manifest.

  online export-db
      Export the App Store PostgreSQL database to exports/.

  online backup-rustfs <db|apps|bundle|all|ls [bucket]>
      Upload backups and bundles to the RustFS object store.

  online test
      Validate the staging deployment is healthy.

PACKAGE:
  package build [--appstore-only] [--include-managed-nextcloud]
      Build a complete air-gapped deployment package into airgapped/.
      Default: App Store images only.
      --appstore-only              Same as default; explicit flag.
      --include-managed-nextcloud  Also include nextcloud:stable-apache image.

AIRGAP (no internet required) — first-time workflow:
  airgap load-images
      Load all Docker images from airgapped/images/ (App Store + Nextcloud).

  airgap deploy compose
      Deploy the full stack: Nextcloud + App Store + databases + nginx + fileserver.
      Imports the App Store database from the bundle on first run.

  airgap deploy k8s
      Deploy the full stack on Kubernetes using pre-loaded images.

  airgap configure-nextcloud
      Connect the deployed Nextcloud instance to the local App Store.
      Installs CA cert, sets appstoreurl, tests connectivity, rolls back on failure.

  airgap test compose
      Validate the Docker Compose deployment (services, DB integrity, NC integration).

  airgap test k8s
      Validate the Kubernetes deployment.

ENVIRONMENT (.env):
  See .env.example for all configurable variables.

EOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# STAGE: online
# ═══════════════════════════════════════════════════════════════════════════════

cmd_online() {
    local action="${1:-}"
    shift || true

    case "${action}" in
        audit)             online_audit ;;
        up)                online_up ;;
        setup-nextcloud)   online_setup_nextcloud ;;
        sync)              online_sync "$@" ;;
        mirror)            online_mirror ;;
        apps)              online_apps "$@" ;;
        export)            online_export "$@" ;;
        export-db)         online_export_db ;;
        backup-rustfs)     online_backup_rustfs "$@" ;;
        test)              online_test ;;
        *)
            echo "Unknown online action: '${action}'"
            usage
            exit 1
            ;;
    esac
}

online_audit() {
    separator
    info "Repository Audit"
    separator
    echo ""
    echo "Project directory: ${PROJECT_DIR}"
    echo ""

    echo "── File layout ────────────────────────────────────────"
    find "${PROJECT_DIR}" -maxdepth 3 -type f \
        | grep -v '\.git/' | grep -v '__pycache__' | grep -v '\.pyc' \
        | sort

    echo ""
    echo "── Docker images ──────────────────────────────────────"
    docker images | grep -E "(nextcloudappstore|postgres|nginx|nextcloud)" || echo "  (none found)"

    echo ""
    echo "── Compose stack status ───────────────────────────────"
    # shellcheck disable=SC2046
    docker compose $(_compose_files) ps 2>/dev/null || echo "  (not running)"

    echo ""
    echo "── Environment ────────────────────────────────────────"
    echo "  APPSTORE_DOMAIN   = ${APPSTORE_DOMAIN}"
    echo "  APPSTORE_API_URL  = ${APPSTORE_API_URL}"
    echo "  FILE_SERVER_URL   = ${FILE_SERVER_URL}"
    echo "  NEXTCLOUD_MODE    = ${NEXTCLOUD_MODE}"
    echo "  NEXTCLOUD_RUNTIME = ${NEXTCLOUD_RUNTIME}"
    echo "  K8S_NAMESPACE     = ${K8S_NAMESPACE}"
    echo ""

    echo "── Exports ────────────────────────────────────────────"
    ls -lh "${PROJECT_DIR}/exports/" 2>/dev/null || echo "  (no exports directory)"
    echo ""
    ls -lh "${AIRGAP_EXPORT_DIR}/" 2>/dev/null || echo "  (no airgapped/exports)"
}

online_up() {
    separator
    info "Starting full stack (App Store + Nextcloud)"
    separator

    require_cmd docker

    # Stage configs for macOS Docker Desktop (Desktop folder bind-mount restriction)
    if _on_macos; then
        _stage_runtime_configs
    fi

    local CF
    CF="$(_compose_files)"

    # Build the App Store image first — it is a custom image built from the
    # local Dockerfile and does not exist on Docker Hub. Without this step
    # Docker Compose would try to pull it and fail.
    info "Building nextcloudappstore image from Dockerfile..."
    # shellcheck disable=SC2086
    docker compose ${CF} build appstore

    info "Starting all services..."
    # shellcheck disable=SC2086
    LOAD_FIXTURES=true IMPORT_TRANSLATIONS=true \
        docker compose ${CF} up -d

    echo ""
    info "Waiting for App Store to be healthy (uWSGI on :8000)..."
    RETRIES=40
    # shellcheck disable=SC2086
    until docker compose ${CF} \
            exec -T appstore python -c \
            "import socket; s=socket.socket(); s.settimeout(5); s.connect(('127.0.0.1',8000)); s.close()" \
            &>/dev/null || [ "${RETRIES}" -eq 0 ]; do
        printf "."
        sleep 3
        RETRIES=$((RETRIES - 1))
    done
    echo ""

    separator
    info "Stack is up"
    echo ""
    echo "  App Store  : https://${APPSTORE_DOMAIN}"
    echo "  Admin      : https://${APPSTORE_DOMAIN}/admin/"
    echo "  File Srv   : http://${FILESERVER_DOMAIN:-${APPSTORE_DOMAIN}}:8082/apps/"
    echo "  Nextcloud  : http://${APPSTORE_DOMAIN}:8083  (installing — wait ~60s on first boot)"
    echo "  RustFS UI  : http://${APPSTORE_DOMAIN}:9001"
    echo ""
    info "Next step: wait for Nextcloud to finish installing, then run:"
    echo "  $0 online setup-nextcloud"
}

online_setup_nextcloud() {
    separator
    info "Connecting Nextcloud to the local App Store"
    separator

    NC_CONTAINER="${NEXTCLOUD_CONTAINER_NAME:-nextcloud}"

    # Wait for Nextcloud to finish its first-boot install
    info "Waiting for Nextcloud to be ready (first boot may take ~60s)..."
    RETRIES=40
    until docker exec "${NC_CONTAINER}" \
            php -r "exit(file_get_contents('http://localhost/status.php') === false ? 1 : 0);" \
            &>/dev/null || [ "${RETRIES}" -eq 0 ]; do
        printf "."
        sleep 5
        RETRIES=$((RETRIES - 1))
    done
    echo ""

    if [ "${RETRIES}" -eq 0 ]; then
        warn "Nextcloud did not become ready in time."
        warn "Check logs: docker logs ${NC_CONTAINER}"
        warn "Then retry: $0 online setup-nextcloud"
        exit 1
    fi

    # Install CA cert inside the NC container so it can verify the App Store's TLS cert
    CA_CERT="${PROJECT_DIR}/k8s/certs/root-ca.crt"
    if [ -f "${CA_CERT}" ]; then
        info "Installing App Store CA certificate inside Nextcloud..."
        docker cp "${CA_CERT}" \
            "${NC_CONTAINER}:/usr/local/share/ca-certificates/appstore-root-ca.crt"
        docker exec "${NC_CONTAINER}" update-ca-certificates 2>/dev/null || \
            warn "update-ca-certificates failed — NC may not trust the App Store cert"
        ok() { echo "[OK]    $*"; }
        ok "CA certificate installed."
    else
        warn "CA cert not found at ${CA_CERT}"
        warn "Run 'bash k8s/generate-certs.sh' first, then re-run this command."
        exit 1
    fi

    # Delegate to the compose configure script (idempotent, backs up, rolls back on failure)
    NEXTCLOUD_CONTAINER_NAME="${NC_CONTAINER}" \
        bash "${AIRGAP_DIR}/scripts/configure-nextcloud-compose.sh" --no-ca

    separator
    info "Nextcloud is connected to the local App Store."
    echo ""
    echo "  Nextcloud   : http://localhost:8083"
    echo "  App Store   : https://localhost"
    echo ""
    info "Next: sync app metadata"
    echo "  $0 online sync"
}

online_sync() {
    separator
    info "Syncing app metadata from official Nextcloud App Store"
    separator
    require_running_appstore
    bash "${SCRIPT_DIR}/sync-apps.sh" "$@"
}

online_mirror() {
    separator
    info "Mirroring app archives"
    separator
    require_running_appstore

    info "Step 1/3: Extracting download URLs from database..."
    bash "${SCRIPT_DIR}/mirror-apps/01-extract-urls.sh"

    info "Step 2/3: Downloading app archives..."
    bash "${SCRIPT_DIR}/mirror-apps/02-download-apps.sh"

    info "Step 3/3: Rewriting database URLs to local fileserver..."
    FILE_SERVER_URL="${FILE_SERVER_URL}" \
        bash "${SCRIPT_DIR}/mirror-apps/03-update-db-urls.sh"

    echo ""
    info "Mirror complete. Re-export the database to capture rewritten URLs:"
    echo "  $0 online export-db"
}

online_apps() {
    local sub="${1:-}"
    shift || true

    case "${sub}" in
        allowlist)
            bash "${SCRIPT_DIR}/apps/manage-allowlist.sh" "$@"
            ;;
        check-compat)
            separator
            info "Checking app compatibility"
            separator
            require_running_appstore
            bash "${SCRIPT_DIR}/apps/check-compatibility.sh" "$@"
            ;;
        report)
            separator
            info "Generating compatibility report"
            separator
            require_running_appstore
            bash "${SCRIPT_DIR}/apps/generate-report.sh" "$@"
            ;;
        mirror-approved)
            separator
            info "Downloading approved compatible app packages"
            separator
            require_running_appstore
            bash "${SCRIPT_DIR}/apps/download-approved.sh" "$@"
            ;;
        *)
            echo "Unknown apps sub-command: '${sub}'"
            echo "Usage: $0 online apps <allowlist|check-compat|report|mirror-approved>"
            exit 1
            ;;
    esac
}

online_export() {
    separator
    info "Building complete air-gapped export bundle"
    separator
    require_running_appstore
    bash "${SCRIPT_DIR}/export-bundle.sh" "$@"

    # Auto-upload bundle + metadata to RustFS when enabled
    if [ "${USE_RUSTFS:-false}" = "true" ]; then
        echo ""
        info "USE_RUSTFS=true — uploading bundle to RustFS..."
        bash "${SCRIPT_DIR}/backup-to-rustfs.sh" bundle
    fi
}

online_export_db() {
    separator
    info "Exporting database"
    separator
    require_running_appstore
    bash "${SCRIPT_DIR}/db/export-db.sh"

    # Auto-upload DB dump to RustFS when enabled
    if [ "${USE_RUSTFS:-false}" = "true" ]; then
        echo ""
        info "USE_RUSTFS=true — uploading DB dump to RustFS..."
        bash "${SCRIPT_DIR}/backup-to-rustfs.sh" db
    fi
}

online_backup_rustfs() {
    separator
    info "Uploading to RustFS object store"
    separator
    bash "${SCRIPT_DIR}/backup-to-rustfs.sh" "$@"
}

online_test() {
    separator
    info "Validating staging deployment"
    separator

    local pass=0 fail=0

    _check() {
        local label="$1" cmd="$2"
        printf "  %-50s " "${label}..."
        if eval "${cmd}" &>/dev/null; then
            echo "OK"; pass=$((pass + 1))
        else
            echo "FAIL"; fail=$((fail + 1))
        fi
    }

    _check "postgres running" \
        "docker inspect appstore-postgres --format='{{.State.Status}}' | grep -q running"
    _check "appstore running" \
        "docker inspect appstore-app --format='{{.State.Status}}' | grep -q running"
    _check "nginx running" \
        "docker inspect appstore-nginx --format='{{.State.Status}}' | grep -q running"
    _check "fileserver running" \
        "docker inspect appstore-fileserver --format='{{.State.Status}}' | grep -q running"
    _check "App Store /health/ HTTPS" \
        "curl -kfs https://localhost/health/"
    _check "App Store API v1 returns JSON" \
        "curl -kfs https://localhost/api/v1/ | grep -q '\['"
    _check "Fileserver /apps/ accessible" \
        "curl -fs http://localhost:8082/apps/"

    echo ""
    echo "Results: ${pass} passed, ${fail} failed"
    [ "${fail}" -eq 0 ] || exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# STAGE: package
# ═══════════════════════════════════════════════════════════════════════════════

cmd_package() {
    local action="${1:-}"
    shift || true

    case "${action}" in
        build) package_build "$@" ;;
        *)
            echo "Unknown package action: '${action}'"
            usage
            exit 1
            ;;
    esac
}

package_build() {
    # Parse flags: --appstore-only (default) vs --include-managed-nextcloud
    local INCLUDE_NEXTCLOUD=false
    for _arg in "$@"; do
        case "${_arg}" in
            --include-managed-nextcloud) INCLUDE_NEXTCLOUD=true ;;
            --appstore-only)             INCLUDE_NEXTCLOUD=false ;;
        esac
    done

    separator
    info "Building air-gapped deployment package"
    info "  include-managed-nextcloud : ${INCLUDE_NEXTCLOUD}"
    separator

    require_cmd docker

    mkdir -p "${AIRGAP_IMAGE_DIR}"
    mkdir -p "${AIRGAP_EXPORT_DIR}"

    local TIMESTAMP
    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

    # ── 1. Build App Store image ──────────────────────────────────────────────
    info "[1] Building nextcloudappstore:latest image..."
    docker build \
        --build-arg APPSTORE_VERSION="${APPSTORE_VERSION:-master}" \
        -t nextcloudappstore:latest \
        -f "${PROJECT_DIR}/Dockerfile" \
        "${PROJECT_DIR}"

    # ── 2. Save images ────────────────────────────────────────────────────────
    local images=("nextcloudappstore:latest" "postgres:15-alpine" "nginx:alpine" "rustfs/rustfs:latest" "minio/mc:latest")
    if [ "${INCLUDE_NEXTCLOUD}" = "true" ]; then
        images+=("nextcloud:stable-apache")
    fi

    for img in "${images[@]}"; do
        local safe_name
        safe_name="$(echo "${img}" | tr ':/' '__')"
        local out="${AIRGAP_IMAGE_DIR}/${safe_name}_${TIMESTAMP}.tar.gz"

        info "[2] Saving image: ${img} → $(basename "${out}")"

        # Pull third-party images (may be a no-op if already present)
        if [ "${img}" != "nextcloudappstore:latest" ]; then
            docker pull "${img}"
        fi

        docker save "${img}" | gzip -c > "${out}"

        if command -v sha256sum &>/dev/null; then
            sha256sum "${out}" > "${out}.sha256"
        elif command -v shasum &>/dev/null; then
            shasum -a 256 "${out}" > "${out}.sha256"
        fi
        info "   Saved: $(du -sh "${out}" | cut -f1)"
    done

    # ── 3. Export database ────────────────────────────────────────────────────
    info "[3] Exporting database..."
    # shellcheck disable=SC2046
    if docker compose $(_compose_files) ps postgres \
            2>/dev/null | grep -q "Up"; then
        bash "${SCRIPT_DIR}/db/export-db.sh"
        # Copy latest dump into airgapped/exports/
        LATEST_DUMP="$(find "${PROJECT_DIR}/exports" -name 'appstore_db_*.sql.gz' \
            2>/dev/null | sort -r | head -1 || true)"
        if [ -n "${LATEST_DUMP}" ]; then
            cp "${LATEST_DUMP}" "${AIRGAP_EXPORT_DIR}/"
            info "   DB dump copied to airgapped/exports/"
        fi
    else
        warn "Postgres is not running — skipping database export."
        warn "Start with: $0 online up  then re-run: $0 package build"
    fi

    # ── 4. Copy mirrored app archives ─────────────────────────────────────────
    info "[4] Copying app archives..."
    local archives_src="${PROJECT_DIR}/exports/app-archives/files"
    if [ -d "${archives_src}" ] && [ -n "$(ls -A "${archives_src}" 2>/dev/null)" ]; then
        mkdir -p "${AIRGAP_EXPORT_DIR}/app-archives/files"
        cp -r "${archives_src}/." "${AIRGAP_EXPORT_DIR}/app-archives/files/"
        local count
        count="$(find "${AIRGAP_EXPORT_DIR}/app-archives/files" -name '*.tar.gz' | wc -l | tr -d ' ')"
        info "   ${count} app archives copied"
    else
        warn "No app archives found at exports/app-archives/files/"
        warn "Run: $0 online mirror  to download them first."
    fi

    # ── 5. Create final package tarball ───────────────────────────────────────
    info "[5] Creating package tarball..."
    local pkg="${PROJECT_DIR}/nextcloud-appstore-airgap-${TIMESTAMP}.tar.gz"
    tar -czf "${pkg}" \
        -C "${PROJECT_DIR}" \
        airgapped/ k8s/ config/ nginx/ fileserver/ scripts/ \
        Dockerfile docker-entrypoint.sh docker-compose.yml .env.example

    local pkg_size
    pkg_size="$(du -sh "${pkg}" | cut -f1)"

    separator
    info "Package build complete"
    echo ""
    echo "  Package   : ${pkg} (${pkg_size})"
    echo "  Images    : ${AIRGAP_IMAGE_DIR}/"
    echo "  DB dump   : ${AIRGAP_EXPORT_DIR}/"
    echo "  App files : ${AIRGAP_EXPORT_DIR}/app-archives/"
    echo ""
    info "Transfer the package or the airgapped/ directory to the air-gapped host."
    info "Then run: $0 airgap load-images"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STAGE: airgap
# ═══════════════════════════════════════════════════════════════════════════════

cmd_airgap() {
    local action="${1:-}"
    shift || true

    case "${action}" in
        load-images)    airgap_load_images ;;
        deploy)         airgap_deploy "$@" ;;
        configure-nextcloud) airgap_configure_nextcloud "$@" ;;
        test)           airgap_test "$@" ;;
        *)
            echo "Unknown airgap action: '${action}'"
            usage
            exit 1
            ;;
    esac
}

airgap_load_images() {
    bash "${AIRGAP_DIR}/scripts/load-images.sh"
}

airgap_deploy() {
    local target="${1:-}"
    case "${target}" in
        compose) bash "${AIRGAP_DIR}/scripts/deploy-compose-airgap.sh" ;;
        k8s)     bash "${AIRGAP_DIR}/scripts/deploy-k8s-airgap.sh" ;;
        *)
            error "Unknown deploy target '${target}'. Use: compose | k8s"
            ;;
    esac
}

airgap_configure_nextcloud() {
    # Default: configure the Nextcloud container deployed by the airgapped compose stack.
    # Override with NEXTCLOUD_RUNTIME=k8s or NEXTCLOUD_RUNTIME=ssh for other deployments.
    local runtime="${NEXTCLOUD_RUNTIME:-compose}"
    separator
    info "Connecting Nextcloud to the local App Store (runtime: ${runtime})"
    separator

    case "${runtime}" in
        compose)
            bash "${AIRGAP_DIR}/scripts/configure-nextcloud-compose.sh"
            ;;
        k8s)
            bash "${AIRGAP_DIR}/scripts/configure-nextcloud-k8s.sh"
            ;;
        ssh)
            bash "${AIRGAP_DIR}/scripts/configure-nextcloud-ssh.sh"
            ;;
        *)
            error "Unknown NEXTCLOUD_RUNTIME '${runtime}'. Set to: compose | k8s | ssh"
            ;;
    esac
}

airgap_test() {
    local target="${1:-compose}"
    bash "${AIRGAP_DIR}/scripts/test-airgap.sh" "${target}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Entry point
# ═══════════════════════════════════════════════════════════════════════════════

STAGE="${1:-}"
if [ -z "${STAGE}" ]; then
    usage
    exit 0
fi
shift

case "${STAGE}" in
    online)  cmd_online "$@" ;;
    package) cmd_package "$@" ;;
    airgap)  cmd_airgap "$@" ;;
    help|--help|-h) usage ;;
    *)
        echo "Unknown stage: '${STAGE}'"
        usage
        exit 1
        ;;
esac
