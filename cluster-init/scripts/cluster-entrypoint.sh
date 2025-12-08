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

# 5.5. Apply ArgoCD root Application manifest (cluster-init)
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

# 6. Run secret generation scripts
echo "\n🔑 Running secret generation scripts..."
"$SCRIPT_DIR/generate-cloudflare-secret.sh"

echo "\n🔍 Showing git diff for review:"
git status
GIT_DIFF=$(git diff)
if [ -z "$GIT_DIFF" ]; then
  echo "✅ No changes detected. Exiting."
  exit 0
fi

echo "$GIT_DIFF" | less

echo "\n❓ Do you want to commit and push these changes to main? (y/n)"
read -r CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  git add .
  git commit -m "Update sealed secrets (TLS, Cloudflare Tunnel) via cluster-entrypoint"
  git push origin main
  echo "\n✅ Changes pushed to main."
else
  echo "❌ Aborted by user. No changes committed."
  exit 1
fi

# 7. Install or upgrade the k0s-cluster-bootstrap Helm chart
echo "\n🚀 Installing or upgrading the k0s-cluster-bootstrap Helm chart..."
helm upgrade --install k0s-cluster-bootstrap .

# 8. Optionally trigger ArgoCD sync (using kubectl instead of CLI)
echo "\n🔄 Optionally trigger ArgoCD application sync? (y/n)"
read -r SYNC_CONFIRM
if [[ "$SYNC_CONFIRM" =~ ^[Yy]$ ]]; then
  read -p "Enter ArgoCD app name (default: cluster-init): " APP_NAME
  APP_NAME=${APP_NAME:-cluster-init}

  # Check if the ArgoCD Application exists
  echo "🔍 Checking if ArgoCD Application '$APP_NAME' exists..."
  if kubectl get application "$APP_NAME" -n argocd &>/dev/null; then
    echo "✅ ArgoCD Application '$APP_NAME' exists, triggering sync..."

    # Trigger hard sync by patching the Application with sync options and annotation
    kubectl patch application "$APP_NAME" -n argocd --type merge -p '{
      "spec": {
        "syncPolicy": {
          "syncOptions": ["Prune=true", "Replace=true"]
        }
      },
      "metadata": {
        "annotations": {
          "argocd.argoproj.io/sync": "true"
        }
      }
    }'

    if [ $? -eq 0 ]; then
      echo "✅ Sync triggered for ArgoCD Application '$APP_NAME'."
      echo "📊 Check sync status with: kubectl get application $APP_NAME -n argocd"
      echo "💡 Alternative: Use ArgoCD UI at https://argocd.benedict-aryo.com"
    else
      echo "❌ Failed to trigger sync for '$APP_NAME'."
      echo "💡 Alternative: Manually sync in ArgoCD UI or use:"
      echo "   kubectl patch application $APP_NAME -n argocd --type merge -p '{\"operation\":{\"sync\":{}}}'"
    fi
  else
    echo "❌ ArgoCD Application '$APP_NAME' does not exist in namespace argocd."
    echo "📋 Available ArgoCD Applications:"
    kubectl get applications -n argocd 2>/dev/null || echo "No applications found or ArgoCD not ready yet."
  fi
fi
