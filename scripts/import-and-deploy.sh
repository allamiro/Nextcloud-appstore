#!/bin/bash
# =============================================================================
# Import and Deploy Script for Air-Gapped Kubernetes
# =============================================================================
# Run this on your disconnected Kubernetes environment
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_DIR="${SCRIPT_DIR}/../exports"

echo "=============================================="
echo "Nextcloud App Store - Import and Deploy"
echo "=============================================="

# Step 1: Load Docker images
echo ""
echo "[1/4] Loading Docker images..."

for file in "${EXPORT_DIR}"/*.tar.gz; do
    if [ -f "$file" ]; then
        echo "  Loading: $(basename "$file")"
        
        # Verify checksum if available
        if [ -f "${file}.sha256" ]; then
            if ! sha256sum -c "${file}.sha256" --quiet 2>/dev/null; then
                echo "    WARNING: Checksum verification failed for $(basename "$file")"
            fi
        fi
        
        gunzip -c "$file" | docker load
    fi
done

# Step 2: Tag images for local registry (if using one)
echo ""
echo "[2/4] Tagging images..."
REGISTRY="${REGISTRY:-}"

if [ -n "${REGISTRY}" ]; then
    echo "  Tagging for registry: ${REGISTRY}"
    docker tag nextcloudappstore:latest "${REGISTRY}/nextcloudappstore:latest"
    docker tag postgres:15-alpine "${REGISTRY}/postgres:15-alpine"
    docker tag nginx:alpine "${REGISTRY}/nginx:alpine"
    
    echo "  Pushing to registry..."
    docker push "${REGISTRY}/nextcloudappstore:latest"
    docker push "${REGISTRY}/postgres:15-alpine"
    docker push "${REGISTRY}/nginx:alpine"
fi

# Step 3: Create Kubernetes namespace and apply manifests
echo ""
echo "[3/4] Deploying to Kubernetes..."

K8S_DIR="${EXPORT_DIR}/k8s"
NAMESPACE="${NAMESPACE:-nextcloud-appstore}"

if [ -d "${K8S_DIR}" ]; then
    # Update image references if using local registry
    if [ -n "${REGISTRY}" ]; then
        echo "  Updating manifests for registry: ${REGISTRY}"
        find "${K8S_DIR}" -name "*.yaml" -exec sed -i "s|image: nextcloudappstore:|image: ${REGISTRY}/nextcloudappstore:|g" {} \;
        find "${K8S_DIR}" -name "*.yaml" -exec sed -i "s|image: postgres:|image: ${REGISTRY}/postgres:|g" {} \;
        find "${K8S_DIR}" -name "*.yaml" -exec sed -i "s|image: nginx:|image: ${REGISTRY}/nginx:|g" {} \;
    fi
    
    echo "  Applying Kubernetes manifests..."
    kubectl apply -f "${K8S_DIR}/namespace.yaml"
    kubectl apply -f "${K8S_DIR}/"
else
    echo "  ERROR: Kubernetes manifests not found at ${K8S_DIR}"
    exit 1
fi

# Step 4: Import database if dump file provided
echo ""
echo "[4/4] Database import..."

DB_DUMP=$(find "${EXPORT_DIR}" -name "appstore_db_*.sql.gz" | sort -r | head -1)

if [ -n "${DB_DUMP}" ] && [ -f "${DB_DUMP}" ]; then
    echo "  Found database dump: $(basename "${DB_DUMP}")"
    echo "  Waiting for PostgreSQL pod to be ready..."
    
    kubectl wait --for=condition=ready pod -l app=postgres -n "${NAMESPACE}" --timeout=120s
    
    # Get PostgreSQL pod name
    PG_POD=$(kubectl get pod -l app=postgres -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
    
    echo "  Importing database into pod: ${PG_POD}"
    gunzip -c "${DB_DUMP}" | kubectl exec -i "${PG_POD}" -n "${NAMESPACE}" -- psql -U nextcloudappstore -d nextcloudappstore
    
    echo "  Database imported successfully!"
else
    echo "  No database dump found. Skipping import."
    echo "  The application will start with an empty database."
fi

echo ""
echo "=============================================="
echo "Deployment Complete!"
echo "=============================================="
echo ""
echo "Check deployment status:"
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get svc -n ${NAMESPACE}"
echo "  kubectl get ingress -n ${NAMESPACE}"
echo ""
echo "View logs:"
echo "  kubectl logs -f deployment/appstore -n ${NAMESPACE}"
echo "=============================================="
