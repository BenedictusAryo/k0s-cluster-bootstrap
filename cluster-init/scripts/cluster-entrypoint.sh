# 8. Apply ArgoCD root Application manifest (if present)
APP_MANIFEST="$REPO_ROOT/manifests/applications/cluster-init-app.yaml"
if [ -f "$APP_MANIFEST" ]; then
  echo "\n📦 Applying ArgoCD root Application (app-of-apps)..."
  kubectl apply -f "$APP_MANIFEST"
  echo "✅ Applied $APP_MANIFEST"
else
  echo "⚠️  $APP_MANIFEST not found, skipping ArgoCD root Application apply."
fi
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

# 3. Install Cilium (if not present)
if ! cilium status &>/dev/null; then
    echo "🌐 Installing Cilium CNI (with Gateway API controller)..."
    cilium install --set kubeProxyReplacement=false --set k8sServiceHost=localhost --set k8sServicePort=6443 --set gatewayAPI.enabled=true --set gatewayAPI.controller.enabled=true --set nodePort.enabled=true --version 1.18.4
    echo "⏳ Waiting for Cilium to be ready..."
    cilium status --wait --wait-duration=5m
    echo "✅ Cilium CNI is ready"
else
    echo "✅ Cilium is already installed"
fi

# 4. Install Sealed Secrets Controller (if not present)
if ! kubectl get deployment sealed-secrets-controller -n kube-system &>/dev/null; then
    echo "🔐 Installing Sealed Secrets Controller..."
    kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.2/controller.yaml
    echo "⏳ Waiting for Sealed Secrets to be ready..."
    kubectl wait --for=condition=available --timeout=180s deployment/sealed-secrets-controller -n kube-system
    echo "✅ Sealed Secrets Controller is ready"
else
    echo "✅ Sealed Secrets Controller is already installed"
fi

# 5. Install ArgoCD using Helm
if ! kubectl get deployment argocd-server -n argocd &>/dev/null; then
    echo "🐙 Installing ArgoCD using Helm..."
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    helm upgrade --install argocd argo/argo-cd \
      --namespace argocd --create-namespace \
      --set server.extraArgs={--insecure}
    echo "⏳ Waiting for ArgoCD to be ready (this may take 2-3 minutes)..."
    kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd
    echo "✅ ArgoCD is ready"
else
    echo "✅ ArgoCD is already installed"
fi

# 6. Run secret generation scripts
echo "\n🔑 Running secret generation scripts..."
"$SCRIPT_DIR/generate-tls-secret.sh"
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

# 7. Optionally trigger ArgoCD sync (if argocd CLI is available)
if command -v argocd &> /dev/null; then
  echo "\n🔄 Optionally sync ArgoCD application? (y/n)"
  read -r SYNC_CONFIRM
  if [[ "$SYNC_CONFIRM" =~ ^[Yy]$ ]]; then
    read -p "Enter ArgoCD app name (default: cluster-init): " APP_NAME
    APP_NAME=${APP_NAME:-cluster-init}

    # Port-forward ArgoCD API server to localhost:8080
    echo "⏳ Port-forwarding ArgoCD API server to localhost:8080..."
    kubectl -n argocd port-forward svc/argocd-server 8080:80 &
    PF_PID=$!
    sleep 5

    # Get ArgoCD admin password from secret
    ARGOCD_PWD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode)

    # Login to ArgoCD CLI
    echo "🔑 Logging in to ArgoCD CLI..."
    argocd login localhost:8080 --username admin --password "$ARGOCD_PWD" --insecure

    # Sync the app
    echo "🔄 Syncing ArgoCD app: $APP_NAME..."
    argocd app sync "$APP_NAME"
    SYNC_EXIT=$?

    # Kill port-forward
    kill $PF_PID
    wait $PF_PID 2>/dev/null

    if [ $SYNC_EXIT -eq 0 ]; then
      echo "✅ ArgoCD sync triggered for $APP_NAME."
    else
      echo "❌ ArgoCD sync failed for $APP_NAME."
    fi
  fi
fi
