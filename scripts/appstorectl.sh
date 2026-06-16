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

require_running_appstore() {
    docker compose -f "${PROJECT_DIR}/docker-compose.yml" ps appstore \
        2>/dev/null | grep -q "Up" \
        || error "App Store container is not running. Start with: $0 online up"
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF

Nextcloud App Store Deployment Toolkit
Usage: $(basename "$0") <stage> <action> [target] [options]

ONLINE (internet required):
  online audit
      Show repo structure, image status, and environment summary.

  online up
      Start the App Store staging stack (docker-compose.yml).

  online up managed-nextcloud
      Also start the optional managed test Nextcloud service.

  online sync [--limit N]
      Sync all app metadata from the official Nextcloud App Store.

  online mirror
      Extract download URLs and download all app .tar.gz archives.

  online export-db
      Export the current PostgreSQL database to exports/.

  online configure-nextcloud <target>
      Configure a Nextcloud instance to use the local App Store.
      Targets: managed-nextcloud | external-compose | external-k8s | external-ssh

  online test
      Validate the staging deployment is healthy.

PACKAGE:
  package build [--appstore-only] [--include-managed-nextcloud]
      Build a complete air-gapped deployment package into airgapped/.
      Default: App Store images only.
      --appstore-only              Same as default; explicit flag.
      --include-managed-nextcloud  Also include nextcloud:stable-apache image.

AIRGAP (no internet required):
  airgap load-images
      Load all images from airgapped/images/ into Docker.

  airgap deploy compose
      Deploy the App Store stack with Docker Compose (air-gapped).

  airgap deploy k8s
      Deploy the App Store stack on Kubernetes (air-gapped).

  airgap configure-nextcloud <target>
      Configure a Nextcloud instance to use the local App Store.
      Targets: external-compose | external-k8s | external-ssh | managed-nextcloud

  airgap test compose
      Validate the Docker Compose air-gapped deployment.

  airgap test k8s
      Validate the Kubernetes air-gapped deployment.

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
        audit)          online_audit ;;
        up)             online_up "$@" ;;
        sync)           online_sync "$@" ;;
        mirror)         online_mirror ;;
        export-db)      online_export_db ;;
        configure-nextcloud) online_configure_nextcloud "$@" ;;
        test)           online_test ;;
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
    docker compose -f "${PROJECT_DIR}/docker-compose.yml" ps 2>/dev/null || echo "  (not running)"

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
    local target="${1:-}"
    separator
    info "Starting App Store staging stack"
    separator

    require_cmd docker

    if [ "${target}" = "managed-nextcloud" ]; then
        info "Including managed test Nextcloud"
        LOAD_FIXTURES=true IMPORT_TRANSLATIONS=true \
            docker compose -f "${PROJECT_DIR}/docker-compose.yml" up -d
    else
        LOAD_FIXTURES=true IMPORT_TRANSLATIONS=true \
            docker compose -f "${PROJECT_DIR}/docker-compose.yml" up -d \
            postgres appstore nginx fileserver
    fi

    echo ""
    info "Waiting for App Store to be healthy..."
    RETRIES=30
    until docker compose -f "${PROJECT_DIR}/docker-compose.yml" \
            exec -T appstore python -c \
            "import urllib.request; urllib.request.urlopen('http://localhost:8000/health/')" \
            &>/dev/null || [ "${RETRIES}" -eq 0 ]; do
        printf "."
        sleep 3
        RETRIES=$((RETRIES - 1))
    done
    echo ""

    separator
    info "Staging stack is up"
    echo ""
    echo "  App Store : https://localhost"
    echo "  Admin     : https://localhost/admin/"
    echo "  File Srv  : http://localhost:8080/apps/"
    echo ""
    info "Next: sync app metadata with: $0 online sync"
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

online_export_db() {
    separator
    info "Exporting database"
    separator
    require_running_appstore
    bash "${SCRIPT_DIR}/db/export-db.sh"
}

online_configure_nextcloud() {
    local target="${1:-}"
    separator
    info "Configure Nextcloud → local App Store (target: ${target})"
    separator

    case "${target}" in
        managed-nextcloud|external-compose)
            bash "${AIRGAP_DIR}/scripts/configure-nextcloud-compose.sh"
            ;;
        external-k8s)
            bash "${AIRGAP_DIR}/scripts/configure-nextcloud-k8s.sh"
            ;;
        external-ssh)
            bash "${AIRGAP_DIR}/scripts/configure-nextcloud-ssh.sh"
            ;;
        *)
            error "Unknown target '${target}'. Choose: managed-nextcloud | external-compose | external-k8s | external-ssh"
            ;;
    esac
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
        "curl -fs http://localhost:8080/apps/"

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
    local include_nextcloud=false
    for arg in "$@"; do
        [ "${arg}" = "--include-managed-nextcloud" ] && include_nextcloud=true
    done

    separator
    info "Building air-gapped deployment package"
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
    local images=("nextcloudappstore:latest" "postgres:15-alpine" "nginx:alpine")
    "${include_nextcloud}" && images+=("nextcloud:stable-apache")

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
    if docker compose -f "${PROJECT_DIR}/docker-compose.yml" ps postgres \
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
    local target="${1:-}"
    separator
    info "Configure Nextcloud → local App Store (air-gapped, target: ${target})"
    separator

    case "${target}" in
        managed-nextcloud|external-compose)
            bash "${AIRGAP_DIR}/scripts/configure-nextcloud-compose.sh"
            ;;
        external-k8s)
            bash "${AIRGAP_DIR}/scripts/configure-nextcloud-k8s.sh"
            ;;
        external-ssh)
            bash "${AIRGAP_DIR}/scripts/configure-nextcloud-ssh.sh"
            ;;
        *)
            error "Unknown target '${target}'. Choose: external-compose | external-k8s | external-ssh | managed-nextcloud"
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
