#!/bin/bash
set -e

# ArgoCD Setup Script
# This script deploys ArgoCD, Sealed Secrets, and configures cluster-serverless
# For VPS/Homelab GitOps-powered serverless platform

echo "🐳 ArgoCD & GitOps Setup"
echo "========================="
echo ""

# Detect script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MANIFESTS_DIR="${SCRIPT_DIR}/../manifests"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found. Checking k0s..."
    if command -v k0s &> /dev/null; then
        echo "   Using k0s kubectl"
        alias kubectl='k0s kubectl'
    else
        echo "   Please ensure k0s is installed and kubeconfig is configured."
        exit 1
    fi
fi

# Verify cluster is accessible
echo "🔍 Verifying cluster connectivity..."
if ! kubectl get nodes &>/dev/null; then
    echo "❌ Cannot connect to cluster. Please check:"
    echo "   1. K0s controller is running: sudo k0s status"
    echo "   2. Kubeconfig is set: export KUBECONFIG=~/.kube/config"
    exit 1
fi

echo "✅ Cluster is accessible"
kubectl get nodes
echo ""

# Create ArgoCD namespace
echo "📦 Creating ArgoCD namespace..."
kubectl apply -f "${MANIFESTS_DIR}/argocd/namespace.yaml"

# Install ArgoCD
echo "🐙 Installing ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "⏳ Waiting for ArgoCD to be ready (this may take 2-3 minutes)..."
kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
echo "✅ ArgoCD is ready"
echo ""

# Wait a bit more for all ArgoCD components
sleep 10

# Deploy cluster-serverless infra (App-of-Apps pattern)
echo "📦 Deploying cluster-serverless infrastructure via ArgoCD..."
kubectl apply -f "${MANIFESTS_DIR}/argocd/cluster-serverless-app.yaml"
echo "✅ Cluster-serverless infra app configured"
echo ""

echo "⏳ Waiting for ArgoCD to sync infrastructure applications..."
echo "   This will deploy: Cilium, Sealed Secrets, Knative, Kourier, OpenTelemetry, Jaeger"
sleep 10

# Get ArgoCD admin password
echo "========================================"
echo "✅ ArgoCD Setup Complete!"
echo "========================================"
echo ""
echo "🔐 ArgoCD Admin Credentials:"
echo "   Username: admin"
echo -n "   Password: "
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "(secret not ready yet, wait a moment)"
echo ""
echo ""
echo "🌐 Access ArgoCD UI:"
echo "   Method 1 - Port Forward (for remote access):"
echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "   Then visit: https://localhost:8080"
echo ""
echo "   Method 2 - Via Cloudflare Tunnel (after setup):"
echo "   https://argocd.benedict-aryo.com"
echo ""
echo "📊 Check ArgoCD Applications:"
echo "   kubectl get applications -n argocd"
echo ""
echo "📝 Next Steps:"
echo "   1. Access ArgoCD UI using the credentials above"
echo "   2. Verify cluster-serverless infra app is syncing: kubectl get app -n argocd"
echo "   3. Configure Cloudflare Tunnel for external access:"
echo ""
echo "      📍 Cloudflare Tunnel Setup for ArgoCD Access:"
echo "      =============================================="
echo "      1. Go to Cloudflare Zero Trust dashboard: https://one.dash.cloudflare.com/"
echo "      2. Navigate to: Networks → Tunnels"
echo "      3. Create or select your tunnel (e.g., 'k0s-homelab-tunnel')"
echo "      4. Go to 'Public Hostname' tab"
echo "      5. Click 'Add a public hostname'"
echo "      6. Configure:"
echo "         - Subdomain: argocd"
echo "         - Domain: benedict-aryo.com"
echo "         - Type: HTTPS"
echo "         - URL: argocd-server.argocd.svc.cluster.local:443"
echo "         - Additional settings:"
echo "           ✓ Enable 'No TLS Verify' (ArgoCD uses self-signed cert)"
echo "      7. Save and wait 1-2 minutes for DNS propagation"
echo "      8. Access: https://argocd.benedict-aryo.com"
echo ""
echo "   4. Deploy your first Knative service"
echo ""
echo "🔗 Useful Resources:"
echo "   ArgoCD Docs: https://argo-cd.readthedocs.io/"
echo "   Knative Docs: https://knative.dev/docs/"
echo ""
