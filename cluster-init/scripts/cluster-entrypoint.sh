#!/bin/bash
set -e

# Entrypoint for cluster-init: runs infra setup, secret generation, git diff/commit/push, triggers ArgoCD sync

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# 1. Install Gateway API CRDs (required for Cilium Gateway)
echo "📦 Installing Gateway API CRDs (required for Cilium Gateway)..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
echo "✅ Gateway API CRDs installed"

# 2. Install Cilium CLI if not present
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

# 3. Install ArgoCD using Helm (needed to bootstrap the infrastructure applications)
if ! kubectl get deployment argocd-server -n argocd &>/dev/null; then
    echo "🐙 Installing ArgoCD using Helm (bootstrap only)..."
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    helm upgrade --install argocd argo/argo-cd \
      --namespace argocd --create-namespace \
      --set server.extraArgs={--insecure}
    echo "⏳ Waiting for ArgoCD to be ready (this may take 2-3 minutes)..."
    kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
    echo "✅ ArgoCD is ready for infrastructure deployment"
else
    echo "✅ ArgoCD is already installed"
fi

# 5. Install Sealed Secrets Controller (required for secret generation)
echo "\n🔐 Installing Sealed Secrets Controller (required for secret generation)..."
if ! kubectl get deployment sealed-secrets-controller -n kube-system &>/dev/null; then
    # Install the Sealed Secrets controller directly to enable sealed secret generation
    kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.2/controller.yaml
    echo "⏳ Waiting for Sealed Secrets controller to be ready..."
    kubectl wait --for=condition=available deployment/sealed-secrets-controller -n kube-system --timeout=180s
    echo "✅ Sealed Secrets controller installed and ready"
else
    echo "✅ Sealed Secrets controller is already installed"
fi

# 6. Apply ArgoCD root Application manifest (cluster-init)
APP_MANIFEST="$REPO_ROOT/cluster-init/cluster-init.yaml"
if [ -f "$APP_MANIFEST" ]; then
  echo "\n📦 Applying ArgoCD root Application (cluster-init)..."
  kubectl apply -f "$APP_MANIFEST"
  echo "✅ Applied $APP_MANIFEST"
  echo "⏳ Waiting for cluster-init ArgoCD application to be processed..."
  sleep 10
  echo "🔄 Forcing hard sync of cluster-init application..."
  kubectl patch application cluster-init -n argocd --type merge -p '{"spec": {"syncPolicy": {"syncOptions": ["Prune=true", "Replace=true"]}}, "metadata": {"annotations": {"argocd.argoproj.io/sync": "true"}}}'
  echo "✅ Hard sync triggered"
else
  echo "⚠️  $APP_MANIFEST not found, skipping ArgoCD root Application apply."
fi

# 7. Collect Cloudflare Tunnel information and update configuration
echo "\n🔐 Configuring Cloudflare Tunnel..."

# Ask for tunnel ID
read -p "Enter Cloudflare Tunnel ID: " TUNNEL_ID
if [ -z "$TUNNEL_ID" ]; then
    echo "❌ Tunnel ID is required"
    exit 1
fi

# Update the values.yaml file with the tunnel ID
# Replace the tunnelId field regardless of its current value
sed -i "/^cloudflareTunnel:/,/^[^[:space:]]/{
    s/^[[:space:]]*tunnelId:.*/  tunnelId: \"$TUNNEL_ID\"/
}" "$REPO_ROOT/values.yaml"

# Enable the cloudflare tunnel in the same section
sed -i "/^cloudflareTunnel:/,/^[^[:space:]]/{
    s/^[[:space:]]*enabled:[[:space:]]*false/  enabled: true/
}" "$REPO_ROOT/values.yaml"

echo "✅ Cloudflare Tunnel ID configured: $TUNNEL_ID"

# Run secret generation scripts
echo "\n🔑 Running secret generation scripts..."
"$SCRIPT_DIR/generate-cloudflare-secret.sh"

echo "\n🔍 Checking for changes..."
# Check for both modified and untracked files
ALL_CHANGES=$(git status --porcelain)
if [ -z "$ALL_CHANGES" ]; then
  echo "✅ No changes detected. Exiting."
  exit 0
fi

echo "📋 Detected changes:"
echo "$ALL_CHANGES"

# Show detailed diff including untracked files
git add .  # Stage all changes including new files
echo "\n🔍 Showing git diff for review:"
git diff --cached

echo "\n❓ Do you want to commit and push these changes to main? (y/n)"
read -r CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  git add .  # Add any new files that might have been missed
  git commit -m "Update sealed secrets (TLS, Cloudflare Tunnel) via cluster-entrypoint"
  git push origin main
  echo "\n✅ Changes pushed to main."
else
  echo "❌ Aborted by user. No changes committed."
  exit 1
fi

echo "\n🔄 The cluster-init ArgoCD Application will now sync the infrastructure from Git."
echo "📊 Monitor sync status: kubectl get application cluster-init -n argocd"
echo "💡 ArgoCD UI: https://argocd.benedict-aryo.com"
echo "   The cluster-init application automatically manages all infrastructure via GitOps."
