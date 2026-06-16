#!/usr/bin/env bash
# =============================================================================
# Validate an air-gapped App Store deployment (Compose or Kubernetes)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/../../"

# Load .env from project root if present
if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

MODE="${1:-compose}"   # compose | k8s
NAMESPACE="${K8S_NAMESPACE:-nextcloud-appstore}"
PASS=0
FAIL=0

check() {
    local label="$1"
    local cmd="$2"
    printf "  %-45s " "${label}..."
    if eval "${cmd}" &>/dev/null; then
        echo "OK"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        FAIL=$((FAIL + 1))
    fi
}

echo "=============================================="
echo "Air-Gapped Deployment Validation (${MODE})"
echo "=============================================="
echo ""

if [ "${MODE}" = "compose" ]; then
    COMPOSE_FILE="${SCRIPT_DIR}/../docker-compose/docker-compose.airgapped.yml"

    echo "--- Docker Compose Services ---"
    check "postgres running" \
        "docker inspect appstore-postgres --format='{{.State.Status}}' | grep -q running"
    check "appstore running" \
        "docker inspect appstore-app --format='{{.State.Status}}' | grep -q running"
    check "nginx running" \
        "docker inspect appstore-nginx --format='{{.State.Status}}' | grep -q running"
    check "fileserver running" \
        "docker inspect appstore-fileserver --format='{{.State.Status}}' | grep -q running"

    echo ""
    echo "--- HTTP Endpoints ---"
    check "App Store /health/ (HTTPS)" \
        "curl -kfs https://localhost:30443/health/"
    check "App Store /api/v1/ returns JSON" \
        "curl -kfs https://localhost:30443/api/v1/ | grep -q '\['"
    check "Fileserver /apps/ listing" \
        "curl -kfs https://localhost:30444/apps/"

elif [ "${MODE}" = "k8s" ]; then
    echo "--- Kubernetes Pods ---"
    check "postgres pod ready" \
        "kubectl get pod -l app=postgres -n ${NAMESPACE} -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
    check "appstore pod ready" \
        "kubectl get pod -l app=appstore -n ${NAMESPACE} -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
    check "nginx pod ready" \
        "kubectl get pod -l app=nginx -n ${NAMESPACE} -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"
    check "fileserver pod ready" \
        "kubectl get pod -l app=fileserver -n ${NAMESPACE} -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True"

    echo ""
    echo "--- HTTP Endpoints ---"
    check "App Store /health/ (HTTPS)" \
        "curl -kfs https://localhost:30443/health/"
    check "App Store /api/v1/ returns JSON" \
        "curl -kfs https://localhost:30443/api/v1/ | grep -q '\['"
    check "Fileserver /apps/ listing" \
        "curl -kfs https://localhost:30444/apps/"
else
    echo "ERROR: Unknown mode '${MODE}'. Use 'compose' or 'k8s'."
    exit 1
fi

echo ""
echo "=============================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "=============================================="

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
