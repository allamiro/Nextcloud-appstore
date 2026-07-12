#!/usr/bin/env bash
# =============================================================================
# Deploy App Store air-gapped stack on Kubernetes
#
# Modes:
#   --appstore-only  (default) Deploy only the App Store services:
#                              postgres, appstore, nginx, fileserver
#   --full-stack               Deploy all services including Nextcloud,
#                              its PostgreSQL, RustFS, and the configure job
#
# Usage:
#   bash deploy-k8s-airgap.sh [--appstore-only|--full-stack]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../k8s"
PROJECT_DIR="${SCRIPT_DIR}/../../"

# Load .env from project root if present
if [ -f "${PROJECT_DIR}/.env" ]; then
    set -a; source "${PROJECT_DIR}/.env"; set +a
fi

NAMESPACE="${K8S_NAMESPACE:-nextcloud-appstore}"
EXPORTS_DIR="${SCRIPT_DIR}/../exports"

# Deployment mode — default to appstore-only so the script never silently
# deploys a Nextcloud the operator may not want.
MODE="appstore-only"
if [ "${1:-}" = "--full-stack" ]; then
    MODE="full-stack"
elif [ "${1:-}" = "--appstore-only" ]; then
    MODE="appstore-only"
elif [ -n "${1:-}" ]; then
    echo "ERROR: unknown flag '${1}'. Use --appstore-only (default) or --full-stack."
    exit 1
fi

# Node IP for URL output. K8S_NODE_IP can be set in .env or in the environment.
# If unset, discover it from the first Ready node.
if [ -z "${K8S_NODE_IP:-}" ]; then
    K8S_NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
fi
K8S_NODE_IP="${K8S_NODE_IP:-<NODE_IP>}"

echo "=============================================="
echo "Deploy Air-Gapped App Store (Kubernetes)"
echo "=============================================="
echo "Namespace : ${NAMESPACE}"
echo "Mode      : ${MODE}"
echo "Node IP   : ${K8S_NODE_IP}"
echo "Manifests : ${K8S_DIR}"
echo ""

# Apply core manifests (common to both modes)
for manifest in \
    "${K8S_DIR}/01-namespace.yaml" \
    "${K8S_DIR}/02-secrets.yaml" \
    "${K8S_DIR}/03-configmap.yaml" \
    "${K8S_DIR}/04-pvc.yaml" \
    "${K8S_DIR}/05-postgres.yaml"; do
    echo "Applying: $(basename "${manifest}")"
    kubectl apply -f "${manifest}"
done

echo ""
echo "Waiting for App Store PostgreSQL to be ready..."
kubectl wait --for=condition=ready pod -l app=postgres \
    -n "${NAMESPACE}" --timeout=120s

# Import database if a dump is available
LATEST_DUMP="$(find "${EXPORTS_DIR}" -name 'appstore_db_*.sql.gz' 2>/dev/null | sort -r | head -1 || true)"
if [ -n "${LATEST_DUMP}" ]; then
    echo ""
    echo "Importing database dump: $(basename "${LATEST_DUMP}")"
    PG_POD="$(kubectl get pod -l app=postgres -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].metadata.name}')"
    kubectl cp "${LATEST_DUMP}" "${NAMESPACE}/${PG_POD}:/tmp/appstore_db.sql.gz"
    kubectl apply -f "${K8S_DIR}/10-import-db-job.yaml"
    kubectl wait --for=condition=complete job/import-appstore-db \
        -n "${NAMESPACE}" --timeout=180s
    echo "Database import complete."
else
    echo "WARNING: No DB dump found in ${EXPORTS_DIR} — App Store will start with an empty database."
fi

echo ""
echo "Ensuring TLS secret exists..."
TLS_SECRET="${PROJECT_DIR}/k8s/09-tls-secret.yaml"
if [ -f "${TLS_SECRET}" ]; then
    kubectl apply -f "${TLS_SECRET}"
else
    echo "WARNING: TLS secret not found at k8s/09-tls-secret.yaml"
    echo "Generate it with: bash k8s/generate-certs.sh"
fi

echo ""
echo "Deploying App Store, Nginx, and Fileserver..."
for manifest in \
    "${K8S_DIR}/06-appstore.yaml" \
    "${K8S_DIR}/07-nginx.yaml" \
    "${K8S_DIR}/08-fileserver.yaml"; do
    echo "Applying: $(basename "${manifest}")"
    kubectl apply -f "${manifest}"
done

echo ""
echo "Waiting for App Store pods..."
kubectl wait --for=condition=ready pod -l app=appstore \
    -n "${NAMESPACE}" --timeout=180s
kubectl wait --for=condition=ready pod -l app=nginx \
    -n "${NAMESPACE}" --timeout=60s
kubectl wait --for=condition=ready pod -l app=fileserver \
    -n "${NAMESPACE}" --timeout=60s

# Full-stack mode: also deploy Nextcloud, its postgres, RustFS, and configure job
if [ "${MODE}" = "full-stack" ]; then
    echo ""
    echo "Full-stack mode: deploying Nextcloud PostgreSQL..."
    kubectl apply -f "${K8S_DIR}/12-postgres-nc.yaml"
    kubectl wait --for=condition=ready pod -l app=postgres-nc \
        -n "${NAMESPACE}" --timeout=120s

    echo "Deploying Nextcloud..."
    kubectl apply -f "${K8S_DIR}/13-nextcloud.yaml"
    kubectl wait --for=condition=ready pod -l app=nextcloud \
        -n "${NAMESPACE}" --timeout=300s

    echo "Deploying RustFS..."
    kubectl apply -f "${K8S_DIR}/14-rustfs.yaml"
    kubectl wait --for=condition=ready pod -l app=rustfs \
        -n "${NAMESPACE}" --timeout=60s
    kubectl apply -f "${K8S_DIR}/15-rustfs-init-job.yaml"
    kubectl wait --for=condition=complete job/rustfs-init \
        -n "${NAMESPACE}" --timeout=120s

    echo "Running configure-nextcloud job..."
    kubectl apply -f "${K8S_DIR}/11-configure-nextcloud-job.yaml"
    kubectl wait --for=condition=complete job/configure-nextcloud \
        -n "${NAMESPACE}" --timeout=120s
fi

echo ""
echo "=============================================="
echo "Air-Gapped Kubernetes Deployment Complete"
echo "=============================================="
echo ""
kubectl get pods -n "${NAMESPACE}"
echo ""
kubectl get svc -n "${NAMESPACE}"
echo ""
echo "  App Store HTTPS : https://${K8S_NODE_IP}:30443"
echo "  App Store Admin : https://${K8S_NODE_IP}:30443/admin/"
echo "  File Server     : https://${K8S_NODE_IP}:30444/apps/"
if [ "${MODE}" = "full-stack" ]; then
    echo "  Nextcloud       : http://${K8S_NODE_IP}:30082"
    echo "  RustFS Console  : http://${K8S_NODE_IP}:30901"
fi
echo ""
echo "Validate:"
echo "  kubectl logs -f deployment/appstore -n ${NAMESPACE}"
echo "  curl -k https://${K8S_NODE_IP}:30443/health/"
echo "  curl -k https://${K8S_NODE_IP}:30444/apps/"
