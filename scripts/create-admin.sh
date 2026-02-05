#!/bin/bash
# =============================================================================
# Create Admin User Script
# =============================================================================
# Run this after deployment to create the initial admin user
# =============================================================================

set -e

NAMESPACE="${NAMESPACE:-nextcloud-appstore}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"

echo "=============================================="
echo "Create Admin User for Nextcloud App Store"
echo "=============================================="
echo "Namespace: ${NAMESPACE}"
echo "Username: ${ADMIN_USER}"
echo "Email: ${ADMIN_EMAIL}"
echo "=============================================="

# Get appstore pod
APPSTORE_POD=$(kubectl get pod -l app=appstore -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}')

if [ -z "${APPSTORE_POD}" ]; then
    echo "ERROR: No appstore pod found in namespace ${NAMESPACE}"
    exit 1
fi

echo "Using pod: ${APPSTORE_POD}"

# Create superuser
echo ""
echo "Creating superuser (you will be prompted for password)..."
kubectl exec -it "${APPSTORE_POD}" -n "${NAMESPACE}" -- \
    python manage.py createsuperuser --username "${ADMIN_USER}" --email "${ADMIN_EMAIL}"

# Verify email
echo ""
echo "Verifying email..."
kubectl exec "${APPSTORE_POD}" -n "${NAMESPACE}" -- \
    python manage.py verifyemail --username "${ADMIN_USER}" --email "${ADMIN_EMAIL}"

echo ""
echo "=============================================="
echo "Admin user created successfully!"
echo "=============================================="
