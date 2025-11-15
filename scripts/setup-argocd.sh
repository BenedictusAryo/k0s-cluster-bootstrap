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

# Install Cilium CNI first (required for pod networking)
echo "🌐 Installing Cilium CNI..."
echo "   This is required for pod networking since we use custom CNI"

# Install Cilium CLI if not present
if ! command -v cilium &> /dev/null; then
    echo "   Installing Cilium CLI..."
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
    curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
    sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
    rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
fi

# Install Cilium with minimal configuration for VPS/homelab
echo "   Installing Cilium to cluster..."
cilium install \
    --set kubeProxyReplacement=strict \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=6443

echo "⏳ Waiting for Cilium to be ready (this may take 2-3 minutes)..."
cilium status --wait --wait-duration=5m
echo "✅ Cilium CNI is ready"
echo ""

# Install Sealed Secrets Controller
echo "🔒 Installing Sealed Secrets Controller..."
# Using specific version to ensure image availability (GHCR, not Docker Hub bitnami)
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.33.1/controller.yaml

echo "⏳ Waiting for Sealed Secrets controller to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment -l app.kubernetes.io/name=sealed-secrets -n kube-system || true
echo "✅ Sealed Secrets controller is ready"
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

# Deploy cluster-serverless application
echo "📦 Deploying cluster-serverless application via ArgoCD..."
kubectl apply -f "${MANIFESTS_DIR}/argocd/cluster-bootstrap-app.yaml"
echo "✅ Cluster-serverless application configured"
echo ""

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
echo "   2. Configure Cloudflare Tunnel for external access"
echo "   3. Verify cluster-serverless app is syncing"
echo "   4. Deploy your first Knative service"
echo ""
echo "🔗 Useful Resources:"
echo "   ArgoCD Docs: https://argo-cd.readthedocs.io/"
echo "   Knative Docs: https://knative.dev/docs/"
echo ""
