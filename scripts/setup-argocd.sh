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
echo "   (Required before ArgoCD pods can start)"

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

# Check if Cilium is already installed
if cilium status &>/dev/null; then
    echo "✅ Cilium is already installed"
else
    # Install Cilium with minimal configuration
    echo "   Installing Cilium to cluster..."
    cilium install \
        --set kubeProxyReplacement=false \
        --set k8sServiceHost=localhost \
        --set k8sServicePort=6443 \
        --version 1.18.4
fi

echo "⏳ Waiting for Cilium to be ready..."
cilium status --wait --wait-duration=5m
echo "✅ Cilium CNI is ready"
echo ""

# Install Knative Operator (manages Knative lifecycle)
echo "📦 Installing Knative Operator v1.17.1..."
kubectl apply -f https://github.com/knative/operator/releases/download/knative-v1.17.1/operator.yaml

echo "⏳ Waiting for Knative Operator to be ready..."
# Wait for the deployment to exist and be available
for i in {1..60}; do
    if kubectl get deployment operator -n knative-operator &>/dev/null; then
        if kubectl wait --for=condition=available --timeout=10s deployment/operator -n knative-operator &>/dev/null; then
            echo "✅ Knative Operator is ready"
            break
        fi
    fi
    if [ $i -eq 60 ]; then
        echo "⚠️  Timeout waiting for Knative Operator, but continuing..."
        kubectl get pods -n knative-operator
    else
        echo "   Waiting for operator deployment... ($i/60)"
        sleep 3
    fi
done
echo ""

# Install Sealed Secrets Controller (for GitOps secret management)
echo "🔐 Installing Sealed Secrets Controller..."
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.2/controller.yaml
echo "⏳ Waiting for Sealed Secrets to be ready..."
kubectl wait --for=condition=available --timeout=180s deployment/sealed-secrets-controller -n kube-system
echo "✅ Sealed Secrets Controller is ready"
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

# Configure ArgoCD resource health checks
echo "🔧 Configuring ArgoCD resource health checks..."
kubectl apply -f "${MANIFESTS_DIR}/argocd/resource-customizations.yaml"
echo "✅ Health checks configured for Knative and SealedSecret resources"
echo ""

# Restart ArgoCD to pick up the new configuration
echo "🔄 Restarting ArgoCD to apply health check configuration..."
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=180s
kubectl rollout status deployment/argocd-server -n argocd --timeout=180s
echo "✅ ArgoCD restarted with new configuration"
echo ""

# Deploy cluster-init app (manages all infrastructure via App-of-Apps pattern)
echo "📦 Deploying cluster-init application (App-of-Apps pattern)..."
kubectl apply -f "${MANIFESTS_DIR}/argocd/cluster-init.yaml"
echo "✅ cluster-init app configured - will manage all infrastructure apps"
echo ""

echo "⏳ Waiting for ArgoCD to sync infrastructure applications..."
echo "   cluster-init will deploy: cluster-serverless-infra (Cilium, Sealed Secrets, Knative, OpenTelemetry, Jaeger)"
sleep 10

# Install Knative Serving
echo ""
echo "📦 Installing Knative Serving v1.17.1..."
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.17.1/serving-crds.yaml
kubectl apply -f https://github.com/knative/serving/releases/download/knative-v1.17.1/serving-core.yaml

# Install Kourier networking layer
echo ""
echo "📦 Installing Kourier v1.17.0..."
kubectl apply -f https://github.com/knative-extensions/net-kourier/releases/download/knative-v1.17.0/kourier.yaml

# Configure Knative to use Kourier
kubectl patch configmap/config-network \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'

# Install Knative Eventing
echo ""
echo "📦 Installing Knative Eventing v1.17.0..."
kubectl apply -f https://github.com/knative/eventing/releases/download/knative-v1.17.0/eventing-crds.yaml
kubectl apply -f https://github.com/knative/eventing/releases/download/knative-v1.17.0/eventing-core.yaml

echo ""
echo "⏳ Waiting for Knative components to be ready..."
kubectl wait --for=condition=Ready pods --all -n knative-serving --timeout=180s
kubectl wait --for=condition=Ready pods --all -n knative-eventing --timeout=180s
kubectl wait --for=condition=Ready pods --all -n kourier-system --timeout=180s

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
