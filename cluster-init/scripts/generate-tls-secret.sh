#!/bin/bash
set -e

# Sealed Secret Generator for Gateway TLS (updated for cert-manager)
# This script helps create any additional TLS secrets, but cert-manager
# now handles main certificates automatically

echo "🔐 Gateway TLS Sealed Secret Generator (cert-manager enabled)"
echo "============================================================="
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
echo "   With cert-manager integrated, certificates are automatically issued from Let's Encrypt."
echo "   This script is for generating additional TLS secrets if needed (not for main gateway)."
echo ""
echo "How do you want to provide the TLS certificate and key?"
echo "  1) Skip - Use cert-manager certificates (recommended)"
echo "  2) Use existing certificate and key files for custom purposes"
read -p "Select option [1/2]: " CERT_OPTION

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
else
    echo "ℹ️  Skipping manual certificate generation - cert-manager will issue certificates automatically."
    echo "   Make sure cert-manager is enabled in values.yaml and Cloudflare API credentials are configured."
    echo "   Certificates will be issued for: *.benedict-aryo.com and benedict-aryo.com"
fi

echo "✅ TLS certificate handling complete (using cert-manager approach)"
