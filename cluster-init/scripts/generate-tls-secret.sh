#!/bin/bash
set -e

# Sealed Secret Generator for Gateway TLS (migrated)
# This script helps create a sealed TLS secret for the Gateway

echo "🔐 Gateway TLS Sealed Secret Generator"
echo "========================================="
echo ""

# Check prerequisites
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl is required but not installed"
    exit 1
fi

if ! command -v kubeseal &> /dev/null; then
    echo "❌ kubeseal is required but not installed"
    echo "   Install with: https://github.com/bitnami-labs/sealed-secrets#installation"
    exit 1
fi

echo "📋 TLS Certificate for Gateway"
echo "   You need a PEM-encoded certificate and key."
echo "   (You can use a real cert or generate a self-signed one with openssl)"
echo ""
echo "How do you want to provide the TLS certificate and key?"
echo "  1) Generate new self-signed certificate (default)"
echo "  2) Use existing certificate and key files"
read -p "Select option [1/2]: " CERT_OPTION
CERT_OPTION=${CERT_OPTION:-1}

if [ "$CERT_OPTION" = "2" ]; then
    read -p "Enter path to TLS certificate (tls.crt): " TLS_CRT
    if [ ! -f "$TLS_CRT" ]; then
        echo "❌ Certificate file not found: $TLS_CRT"
        exit 1
    fi
    read -p "Enter path to TLS private key (tls.key): " TLS_KEY
    if [ ! -f "$TLS_KEY" ]; then
        echo "❌ Key file not found: $TLS_KEY"
        exit 1
    fi
else
    if ! command -v openssl &> /dev/null; then
        echo "❌ openssl is required to generate a self-signed certificate but is not installed."
        exit 1
    fi
    echo "Generating new self-signed certificate using openssl..."
    TLS_CRT="$(mktemp)"
    TLS_KEY="$(mktemp)"
    OPENSSL_CONF_FILE="$(mktemp)"
    cat > "$OPENSSL_CONF_FILE" << 'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
CN=*.benedict-aryo.com

[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.benedict-aryo.com
DNS.2 = benedict-aryo.com
EOF
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -config "$OPENSSL_CONF_FILE" \
        -extensions v3_req \
        -keyout "$TLS_KEY" -out "$TLS_CRT"
    rm "$OPENSSL_CONF_FILE"
    echo "  Self-signed certificate generated for benedict-aryo.com and *.benedict-aryo.com (valid 1 year)"
fi

# Create namespace if not exists (for kubeseal to work)
kubectl create namespace gateway-system --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

# Create temporary secret
kubectl create secret tls wildcard-tls-cert \
  --namespace=gateway-system \
  --cert="$TLS_CRT" \
  --key="$TLS_KEY" \
  --dry-run=client -o yaml > /tmp/wildcard-tls-cert.yaml

kubeseal --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --format=yaml < /tmp/wildcard-tls-cert.yaml > /tmp/wildcard-tls-cert-sealed.yaml

# Move sealed secret to templates directory
TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/templates/gateway"
mkdir -p "$TARGET_DIR"
cp /tmp/wildcard-tls-cert-sealed.yaml "$TARGET_DIR/secret.yaml"

rm /tmp/wildcard-tls-cert.yaml /tmp/wildcard-tls-cert-sealed.yaml

echo "✅ Sealed secret written to $TARGET_DIR/secret.yaml"
