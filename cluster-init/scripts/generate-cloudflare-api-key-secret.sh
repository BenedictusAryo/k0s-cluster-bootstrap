#!/bin/bash
set -e

echo "🔐 Cloudflare API Key Sealed Secret Generator"
echo "============================================="
echo ""

# Check prerequisites
if ! command -v kubectl &> /dev/null;
then
    echo "❌ kubectl is required but not installed"
    exit 1
fi

if ! command -v kubeseal &> /dev/null;
then
    echo "❌ kubeseal is required but not installed"
    echo "   Install with: https://github.com/bitnami-labs/sealed-secrets#installation"
    exit 1
fi

# Check if sealed-secrets controller is running
echo "🔍 Checking Sealed Secrets controller..."
if ! kubectl get deployment -n kube-system sealed-secrets-controller &>/dev/null;
then
    echo "❌ Sealed Secrets controller not found in cluster"
    echo "   Make sure you've run the k0s-cluster-bootstrap setup scripts first"
    exit 1
fi
echo "✅ Sealed Secrets controller is running"
echo ""

# Interactive input
echo "📋 Cloudflare API Key Configuration"
echo "   (Get your API Token from https://dash.cloudflare.com/profile/api)"
echo ""
echo "   Steps to get your API Token:"
echo "   1. Go to your Cloudflare profile page."
echo "   2. In the 'API Tokens' section, click 'Create Token'."
echo "   3. Use the 'Edit Cloudflare DNS' template or create a custom token with Zone.DNS edit permissions."
echo "   4. Ensure the token has access to the specific zones you need to manage."
echo ""

read -p "Enter Cloudflare API Token: " CLOUDFLARE_API_TOKEN
if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
    echo "❌ Cloudflare API Token is required"
    exit 1
fi

# Create namespace if not exists (for kubeseal to work)
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

# Create temporary secret
echo ""
echo "🔒 Generating sealed secret..."

kubectl create secret generic cloudflare-api-key \
  --namespace=cert-manager \
  --from-literal=api-key="$CLOUDFLARE_API_TOKEN" \
  --dry-run=client -o yaml > /tmp/cloudflare-api-key-secret.yaml

kubeseal --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --format=yaml < /tmp/cloudflare-api-key-secret.yaml > /tmp/cloudflare-api-key-sealed.yaml

# Move sealed secret to templates directory
TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/templates"
mkdir -p "$TARGET_DIR"
cp /tmp/cloudflare-api-key-sealed.yaml "$TARGET_DIR/cloudflare-api-key-secret.yaml"

rm /tmp/cloudflare-api-key-secret.yaml /tmp/cloudflare-api-key-sealed.yaml

echo "✅ Sealed secret written to $TARGET_DIR/cloudflare-api-key-secret.yaml"
