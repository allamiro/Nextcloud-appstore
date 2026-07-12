#!/bin/bash
# =============================================================================
# Generate Self-Signed CA Chain and Server Certificates for Nextcloud App Store
# =============================================================================
# This script creates:
#   1. Root CA certificate and key
#   2. Intermediate CA certificate and key (signed by Root CA)
#   3. Server certificate and key (signed by Intermediate CA)
#   4. CA chain file (Intermediate + Root)
#   5. Kubernetes TLS secret
# =============================================================================

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/certs"
DAYS_ROOT=3650      # 10 years for Root CA
DAYS_INTERMEDIATE=1825  # 5 years for Intermediate CA
DAYS_SERVER=365     # 1 year for server cert

# Server details - adjust for your environment
SERVER_CN="${SERVER_CN:-localhost}"
SERVER_ALT_NAMES="${SERVER_ALT_NAMES:-DNS:localhost,DNS:appstore.local,IP:127.0.0.1}"

# Organization details
ORG_COUNTRY="US"
ORG_STATE="California"
ORG_LOCALITY="San Francisco"
ORG_NAME="Nextcloud App Store"
ORG_UNIT="IT Department"

echo "=============================================="
echo "Generating SSL Certificate Chain"
echo "=============================================="
echo "Server CN: ${SERVER_CN}"
echo "Alt Names: ${SERVER_ALT_NAMES}"
echo "Output Dir: ${CERTS_DIR}"
echo "=============================================="

# Create certs directory
mkdir -p "${CERTS_DIR}"
cd "${CERTS_DIR}"

# =============================================================================
# Step 1: Generate Root CA
# =============================================================================
echo ""
echo "[1/5] Generating Root CA..."

# Root CA private key
openssl genrsa -out root-ca.key 4096

# Root CA certificate
openssl req -x509 -new -nodes \
    -key root-ca.key \
    -sha256 \
    -days ${DAYS_ROOT} \
    -out root-ca.crt \
    -subj "/C=${ORG_COUNTRY}/ST=${ORG_STATE}/L=${ORG_LOCALITY}/O=${ORG_NAME}/OU=${ORG_UNIT}/CN=${ORG_NAME} Root CA"

echo "  ✓ Root CA created: root-ca.crt, root-ca.key"

# =============================================================================
# Step 2: Generate Intermediate CA
# =============================================================================
echo ""
echo "[2/5] Generating Intermediate CA..."

# Intermediate CA private key
openssl genrsa -out intermediate-ca.key 4096

# Intermediate CA CSR
openssl req -new \
    -key intermediate-ca.key \
    -out intermediate-ca.csr \
    -subj "/C=${ORG_COUNTRY}/ST=${ORG_STATE}/L=${ORG_LOCALITY}/O=${ORG_NAME}/OU=${ORG_UNIT}/CN=${ORG_NAME} Intermediate CA"

# Intermediate CA config for signing
cat > intermediate-ca.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,digitalSignature,cRLSign,keyCertSign
EOF

# Sign Intermediate CA with Root CA
openssl x509 -req \
    -in intermediate-ca.csr \
    -CA root-ca.crt \
    -CAkey root-ca.key \
    -CAcreateserial \
    -out intermediate-ca.crt \
    -days ${DAYS_INTERMEDIATE} \
    -sha256 \
    -extfile intermediate-ca.ext

echo "  ✓ Intermediate CA created: intermediate-ca.crt, intermediate-ca.key"

# =============================================================================
# Step 3: Generate Server Certificate
# =============================================================================
echo ""
echo "[3/5] Generating Server Certificate..."

# Server private key
openssl genrsa -out server.key 2048

# Server CSR
openssl req -new \
    -key server.key \
    -out server.csr \
    -subj "/C=${ORG_COUNTRY}/ST=${ORG_STATE}/L=${ORG_LOCALITY}/O=${ORG_NAME}/OU=${ORG_UNIT}/CN=${SERVER_CN}"

# Server certificate config
cat > server.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=${SERVER_ALT_NAMES}
EOF

# Sign Server cert with Intermediate CA
openssl x509 -req \
    -in server.csr \
    -CA intermediate-ca.crt \
    -CAkey intermediate-ca.key \
    -CAcreateserial \
    -out server.crt \
    -days ${DAYS_SERVER} \
    -sha256 \
    -extfile server.ext

echo "  ✓ Server certificate created: server.crt, server.key"

# =============================================================================
# Step 4: Create Certificate Chain Files
# =============================================================================
echo ""
echo "[4/5] Creating certificate chain files..."

# Full chain (server + intermediate + root) for Nginx
cat server.crt intermediate-ca.crt root-ca.crt > server-chain.crt

# CA chain only (intermediate + root) for client verification
cat intermediate-ca.crt root-ca.crt > ca-chain.crt

echo "  ✓ Chain files created: server-chain.crt, ca-chain.crt"

# =============================================================================
# Step 5: Create Kubernetes Secret YAML
# =============================================================================
echo ""
echo "[5/5] Creating Kubernetes TLS secret..."

# Base64 encode for Kubernetes secret
TLS_CRT_B64=$(base64 < server-chain.crt | tr -d '\n')
TLS_KEY_B64=$(base64 < server.key | tr -d '\n')
CA_CRT_B64=$(base64 < ca-chain.crt | tr -d '\n')

cat > "${SCRIPT_DIR}/09-tls-secret.yaml" << EOF
# =============================================================================
# TLS Secret for Nextcloud App Store
# =============================================================================
# Generated by generate-certs.sh on $(date)
# Server CN: ${SERVER_CN}
# Alt Names: ${SERVER_ALT_NAMES}
# =============================================================================
apiVersion: v1
kind: Secret
metadata:
  name: appstore-tls
  namespace: nextcloud-appstore
  labels:
    app.kubernetes.io/name: nextcloud-appstore
    app.kubernetes.io/component: tls
type: Opaque
data:
  tls.crt: ${TLS_CRT_B64}
  tls.key: ${TLS_KEY_B64}
  ca.crt: ${CA_CRT_B64}
EOF

echo "  ✓ Kubernetes secret created: ${SCRIPT_DIR}/09-tls-secret.yaml"

# =============================================================================
# Copy certs to nginx/ssl/ so Docker Compose nginx can pick them up.
# Uses server-chain.crt (server + intermediate + root) as the TLS certificate
# so clients can validate the full chain without needing the CA pre-installed.
# =============================================================================
NGINX_SSL_DIR="${SCRIPT_DIR}/../nginx/ssl"
mkdir -p "${NGINX_SSL_DIR}"

cp "${CERTS_DIR}/server-chain.crt" "${NGINX_SSL_DIR}/server.crt"
cp "${CERTS_DIR}/server.key"       "${NGINX_SSL_DIR}/server.key"
cp "${CERTS_DIR}/root-ca.crt"      "${NGINX_SSL_DIR}/root-ca.crt"

echo ""
echo "[AUTO] Certs copied to nginx/ssl/ for Docker Compose:"
echo "  server.crt  ← server-chain.crt (full chain)"
echo "  server.key  ← server.key"
echo "  root-ca.crt ← root-ca.crt"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=============================================="
echo "Certificate Generation Complete!"
echo "=============================================="
echo ""
echo "Source files: ${CERTS_DIR}/"
echo "  root-ca.crt / root-ca.key       — Root CA  (10 yr)"
echo "  intermediate-ca.crt / .key      — Intermediate CA  (5 yr)"
echo "  server.crt / server.key         — Server cert  (1 yr)"
echo "  server-chain.crt                — Full chain for nginx"
echo "  ca-chain.crt                    — CA chain for client verification"
echo ""
echo "Copied to: ${NGINX_SSL_DIR}/"
echo "  server.crt  server.key  root-ca.crt"
echo ""
echo "Kubernetes manifest:"
echo "  ${SCRIPT_DIR}/09-tls-secret.yaml"
echo ""
echo "To regenerate with a specific IP or hostname:"
echo "  SERVER_CN=192.168.178.165 \\"
echo "  SERVER_ALT_NAMES='IP:192.168.178.165,DNS:localhost,DNS:appstore.local' \\"
echo "  bash k8s/generate-certs.sh"
echo ""
echo "To trust the Root CA on macOS (so browser shows green lock):"
echo "  sudo security add-trusted-cert -d -r trustRoot \\"
echo "    -k /Library/Keychains/System.keychain ${CERTS_DIR}/root-ca.crt"
echo ""
echo "To trust the Root CA on Linux:"
echo "  sudo cp ${CERTS_DIR}/root-ca.crt /usr/local/share/ca-certificates/appstore-root-ca.crt"
echo "  sudo update-ca-certificates"
echo ""
echo "Server cert expires in: 365 days. Regenerate before expiry."
echo "=============================================="
