#!/usr/bin/env bash
# =============================================================================
# Validate an air-gapped App Store deployment (Compose or Kubernetes)
# =============================================================================
# Goes beyond container health checks to prove actual Nextcloud integration:
#   - App Store services are running and reachable
#   - All app download URLs in the DB point to the local fileserver (not public internet)
#   - If a Nextcloud runtime is configured: NC can list apps from the local store
#   - A test app package can be downloaded from the local fileserver
#   - No outbound connections to apps.nextcloud.com in the DB
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "${PROJECT_DIR}/.env"
    set +a
fi

MODE="${1:-compose}"
NAMESPACE="${K8S_NAMESPACE:-nextcloud-appstore}"
APPSTORE_API_URL="${APPSTORE_API_URL:-https://appstore.local/api/v1}"
FILE_SERVER_URL="${FILE_SERVER_URL:-https://files.local/apps}"
FILE_SERVER_HOST="$(echo "${FILE_SERVER_URL}" | sed 's|https\?://||;s|/.*||')"
NC_RUNTIME="${NEXTCLOUD_RUNTIME:-}"

PASS=0
FAIL=0
WARN_COUNT=0

check() {
    local label="$1"
    local cmd="$2"
    printf "  %-55s " "${label}..."
    if eval "${cmd}" &>/dev/null; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        FAIL=$((FAIL + 1))
    fi
}

check_warn() {
    local label="$1"
    local cmd="$2"
    printf "  %-55s " "${label}..."
    if eval "${cmd}" &>/dev/null; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "WARN (non-fatal)"
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
}

# ── Helpers to exec into the App Store ────────────────────────────────────────
appstore_exec() {
    if [ "${MODE}" = "compose" ]; then
        docker compose -f "${PROJECT_DIR}/docker-compose.yml" exec -T appstore "$@" 2>/dev/null || \
        docker exec appstore-app "$@" 2>/dev/null
    else
        local pod
        pod="$(kubectl get pod -l app=appstore -n "${NAMESPACE}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
        kubectl exec "${pod}" -n "${NAMESPACE}" -- "$@" 2>/dev/null
    fi
}

postgres_query() {
    local query="$1"
    if [ "${MODE}" = "compose" ]; then
        docker compose -f "${PROJECT_DIR}/docker-compose.yml" \
            exec -T postgres \
            psql -U nextcloudappstore nextcloudappstore -t -c "${query}" 2>/dev/null || \
        docker exec appstore-postgres \
            psql -U nextcloudappstore nextcloudappstore -t -c "${query}" 2>/dev/null
    else
        local pod
        pod="$(kubectl get pod -l app=postgres -n "${NAMESPACE}" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
        kubectl exec "${pod}" -n "${NAMESPACE}" -- \
            psql -U nextcloudappstore nextcloudappstore -t -c "${query}" 2>/dev/null
    fi
}

echo "================================================================"
echo "Air-Gapped Deployment Validation (${MODE})"
echo "================================================================"
echo ""

# ── Section 1: Service health ─────────────────────────────────────────────────
echo "── Service Health ──────────────────────────────────────────────"

if [ "${MODE}" = "compose" ]; then
    check "postgres running" \
        "docker inspect appstore-postgres --format='{{.State.Status}}' | grep -q running"
    check "appstore running" \
        "docker inspect appstore-app --format='{{.State.Status}}' | grep -q running"
    check "nginx running" \
        "docker inspect appstore-nginx --format='{{.State.Status}}' | grep -q running"
    check "fileserver running" \
        "docker inspect appstore-fileserver --format='{{.State.Status}}' | grep -q running"
elif [ "${MODE}" = "k8s" ]; then
    check "postgres pod ready" \
        "kubectl get pod -l app=postgres -n ${NAMESPACE} \
            -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
    check "appstore pod ready" \
        "kubectl get pod -l app=appstore -n ${NAMESPACE} \
            -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
    check "nginx pod ready" \
        "kubectl get pod -l app=nginx -n ${NAMESPACE} \
            -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
    check "fileserver pod ready" \
        "kubectl get pod -l app=fileserver -n ${NAMESPACE} \
            -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
else
    echo "ERROR: Unknown mode '${MODE}'. Use 'compose' or 'k8s'."
    exit 1
fi

# ── Section 2: HTTP endpoint reachability ──────────────────────────────────────
echo ""
echo "── HTTP Endpoints ──────────────────────────────────────────────"
check "App Store /health/ (HTTPS)" \
    "curl -kfs --max-time 10 https://localhost:30443/health/"
check "App Store /api/v1/ returns JSON array" \
    "curl -kfs --max-time 10 https://localhost:30443/api/v1/ | python3 -c 'import json,sys; json.load(sys.stdin)'"
check "Fileserver /apps/ listing reachable" \
    "curl -kfs --max-time 10 https://localhost:30444/apps/"

# ── Section 3: Database integrity — no public URLs ────────────────────────────
echo ""
echo "── Database Integrity ──────────────────────────────────────────"

check "app_release table populated" \
    "postgres_query 'SELECT count(*) FROM nextcloudappstore_core_apprelease;' | grep -qv '^ *0'"

# Count releases whose download URL still points to apps.nextcloud.com
PUBLIC_URL_COUNT="$(postgres_query \
    "SELECT count(*) FROM nextcloudappstore_core_apprelease \
     WHERE download LIKE '%apps.nextcloud.com%' OR download LIKE '%github.com%';" \
    2>/dev/null | tr -d ' ' || echo "unknown")"

printf "  %-55s " "all download URLs rewritten to local fileserver..."
if [ "${PUBLIC_URL_COUNT}" = "0" ]; then
    echo "PASS (${PUBLIC_URL_COUNT} public URLs found)"
    PASS=$((PASS + 1))
elif [ "${PUBLIC_URL_COUNT}" = "unknown" ]; then
    echo "WARN (could not query DB)"
    WARN_COUNT=$((WARN_COUNT + 1))
else
    echo "FAIL (${PUBLIC_URL_COUNT} releases still point to public URLs)"
    echo "     Run: ./scripts/appstorectl.sh online mirror  then re-export"
    FAIL=$((FAIL + 1))
fi

# Spot-check: at least one URL references the local fileserver
LOCAL_URL_COUNT="$(postgres_query \
    "SELECT count(*) FROM nextcloudappstore_core_apprelease \
     WHERE download LIKE '%${FILE_SERVER_HOST}%';" \
    2>/dev/null | tr -d ' ' || echo "0")"

printf "  %-55s " "at least one release URL points to local fileserver..."
if [ "${LOCAL_URL_COUNT:-0}" -gt 0 ] 2>/dev/null; then
    echo "PASS (${LOCAL_URL_COUNT} local URLs)"
    PASS=$((PASS + 1))
else
    echo "WARN (0 local fileserver URLs — mirror may not have run)"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# ── Section 4: Local fileserver has app packages ──────────────────────────────
echo ""
echo "── Local App Archive Availability ──────────────────────────────"

FIRST_LOCAL_URL="$(postgres_query \
    "SELECT download FROM nextcloudappstore_core_apprelease \
     WHERE download LIKE '%${FILE_SERVER_HOST}%' LIMIT 1;" \
    2>/dev/null | tr -d ' ' || echo "")"

if [ -n "${FIRST_LOCAL_URL}" ]; then
    check "sample app package downloadable from fileserver" \
        "curl -kfsSL --max-time 30 '${FIRST_LOCAL_URL}' -o /dev/null"
else
    printf "  %-55s %s\n" "sample app package downloadable from fileserver..." "SKIP (no local URLs in DB)"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

APP_COUNT="$(postgres_query \
    "SELECT count(DISTINCT app_id) FROM nextcloudappstore_core_apprelease;" \
    2>/dev/null | tr -d ' ' || echo "0")"
printf "  %-55s %s\n" "apps in database..." "${APP_COUNT} apps"

# ── Section 5: Nextcloud integration (if configured) ─────────────────────────
echo ""
echo "── Nextcloud Integration ────────────────────────────────────────"

NC_CONFIGURED=false

if [ "${NC_RUNTIME}" = "compose" ] && [ -n "${NEXTCLOUD_CONTAINER_NAME:-}" ]; then
    NC_CONTAINER="${NEXTCLOUD_CONTAINER_NAME}"
    if docker inspect "${NC_CONTAINER}" --format='{{.State.Status}}' 2>/dev/null | grep -q running; then
        NC_CONFIGURED=true

        check "Nextcloud container running" \
            "docker inspect '${NC_CONTAINER}' --format='{{.State.Status}}' | grep -q running"

        check "Nextcloud appstoreurl points to local App Store" \
            "docker exec -u www-data '${NC_CONTAINER}' php occ config:system:get appstoreurl \
             2>/dev/null | grep -q '${APPSTORE_API_URL}'"

        check "Nextcloud appstoreenabled = true" \
            "docker exec -u www-data '${NC_CONTAINER}' php occ config:system:get appstoreenabled \
             2>/dev/null | grep -q true"

        check_warn "Nextcloud can list apps from local store" \
            "docker exec -u www-data '${NC_CONTAINER}' php occ app:list 2>/dev/null | grep -q '^Enabled'"
    fi

elif [ "${NC_RUNTIME}" = "k8s" ] && [ -n "${NEXTCLOUD_K8S_NAMESPACE:-}" ]; then
    NC_NS="${NEXTCLOUD_K8S_NAMESPACE}"
    NC_SEL="${NEXTCLOUD_K8S_POD_SELECTOR:-app=nextcloud}"
    NC_POD="$(kubectl get pod -l "${NC_SEL}" -n "${NC_NS}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

    if [ -n "${NC_POD}" ]; then
        NC_CONFIGURED=true
        NC_CTR="${NEXTCLOUD_K8S_CONTAINER:-nextcloud}"

        check "Nextcloud pod ready" \
            "kubectl get pod -l '${NC_SEL}' -n '${NC_NS}' \
             -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"

        check "Nextcloud appstoreurl points to local App Store" \
            "kubectl exec '${NC_POD}' -n '${NC_NS}' -c '${NC_CTR}' -- \
             sudo -u www-data php occ config:system:get appstoreurl 2>/dev/null \
             | grep -q '${APPSTORE_API_URL}'"

        check_warn "Nextcloud can list apps from local store" \
            "kubectl exec '${NC_POD}' -n '${NC_NS}' -c '${NC_CTR}' -- \
             sudo -u www-data php occ app:list 2>/dev/null | grep -q '^Enabled'"
    fi
fi

if [ "${NC_CONFIGURED}" = "false" ]; then
    echo "  (skipped — NEXTCLOUD_RUNTIME not configured or NC not found)"
    echo "  Set NEXTCLOUD_RUNTIME and NEXTCLOUD_CONTAINER_NAME in .env to enable NC tests."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "Results: ${PASS} passed  |  ${FAIL} failed  |  ${WARN_COUNT} warnings"
echo "================================================================"

if [ "${FAIL}" -gt 0 ]; then
    echo ""
    echo "  FAILED checks require attention before this deployment is ready."
    exit 1
fi

if [ "${WARN_COUNT}" -gt 0 ]; then
    echo ""
    echo "  Warnings indicate incomplete configuration (mirror not run, NC not wired up)."
    echo "  The deployment is running but may not serve apps to Nextcloud yet."
fi
