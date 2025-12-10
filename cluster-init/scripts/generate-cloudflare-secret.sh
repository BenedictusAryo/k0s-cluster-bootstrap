#!/bin/bash
set -e

# Sealed Secret Generator for Cloudflare Tunnel (migrated)
# This script helps create encrypted secrets for GitOps deployment

echo "🔐 Cloudflare Tunnel Sealed Secret Generator"
echo "============================================="
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

# Check if sealed-secrets controller is running
echo "🔍 Checking Sealed Secrets controller..."
if ! kubectl get deployment -n kube-system sealed-secrets-controller &>/dev/null; then
    echo "❌ Sealed Secrets controller not found in cluster"
    echo "   Make sure you've run the k0s-cluster-bootstrap setup scripts first"
    exit 1
fi
echo "✅ Sealed Secrets controller is running"
echo ""

# Interactive input
echo "📋 Cloudflare Tunnel Configuration"
echo "   (Get your tunnel token from https://one.dash.cloudflare.com/)"
echo ""
echo "   Steps to get your tunnel token:"
echo "   1. Go to Zero Trust dashboard → Networks → Tunnels"
echo "   2. Create a new tunnel or select existing one"
echo "   3. Copy the tunnel token from the installation command"
echo ""

read -p "Enter Cloudflare Tunnel Token: " TUNNEL_TOKEN
if [ -z "$TUNNEL_TOKEN" ]; then
    echo "❌ Tunnel token is required"
    exit 1
fi

# Create namespace if not exists (for kubeseal to work)
kubectl create namespace cloudflare --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

# Create temporary secret
echo ""
echo "🔒 Generating sealed secret..."

kubectl create secret generic cloudflare-tunnel \
  --namespace=cloudflare \
  --from-literal=tunnel-token="$TUNNEL_TOKEN" \
  --dry-run=client -o yaml > /tmp/cloudflare-tunnel-secret.yaml

kubeseal --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --format=yaml < /tmp/cloudflare-tunnel-secret.yaml > /tmp/cloudflare-tunnel-sealed.yaml

# Move sealed secret to templates directory
TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/templates"
mkdir -p "$TARGET_DIR"
cp /tmp/cloudflare-tunnel-sealed.yaml "$TARGET_DIR/cloudflare-tunnel-secret.yaml"

rm /tmp/cloudflare-tunnel-secret.yaml /tmp/cloudflare-tunnel-sealed.yaml

echo "✅ Sealed secret written to $TARGET_DIR/secret.yaml"
