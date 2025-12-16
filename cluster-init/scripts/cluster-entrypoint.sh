#!/bin/bash
set -e

# Entrypoint for cluster-init: runs infra setup, secret generation, git diff/commit/push, triggers ArgoCD sync

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# 1. Install Cilium CNI first (before any other networking-dependent components)
echo "📦 Installing Cilium CNI as the primary network plugin (required before other components)..."
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

# Install Cilium with basic configuration to ensure networking works before deploying other components
cilium install --version 1.15.3 --namespace kube-system --set kubeProxyReplacement=disabled --set k8sServiceHost=localhost --set k8sServicePort=6443

# Wait for Cilium to be ready before proceeding
echo "⏳ Waiting for Cilium to be ready..."
kubectl wait --for=condition=ready pods -l k8s-app=cilium -n kube-system --timeout=300s
kubectl wait --for=condition=ready pods -l app.kubernetes.io/name=cilium-operator -n kube-system --timeout=300s
echo "✅ Cilium CNI is ready!"

# 2. Install Gateway API CRDs (required for Cilium Gateway)
echo "📦 Installing Gateway API CRDs (required for Cilium Gateway)..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
echo "✅ Gateway API CRDs installed"

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

# 4. Install Sealed Secrets Controller (required for secret generation)
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

# 5. Apply ArgoCD root Application manifest (cluster-init)
APP_MANIFEST="$REPO_ROOT/cluster-init/cluster-init.yaml"
if [ -f "$APP_MANIFEST" ]; then
  echo "\n📦 Applying ArgoCD root Application (cluster-init)..."
  kubectl apply -f "$APP_MANIFEST"
  echo "✅ Applied $APP_MANIFEST"

  echo "🔄 Forcing hard sync of cluster-init application to begin infrastructure deployment..."
  kubectl patch application cluster-init -n argocd --type merge -p '{"spec": {"syncPolicy": {"syncOptions": ["Prune=true", "Replace=true"]}}, "metadata": {"annotations": {"argocd.argoproj.io/sync": "true"}}}'
  echo "✅ Hard sync triggered"
else
  echo "⚠️  $APP_MANIFEST not found, skipping ArgoCD root Application apply."
fi



# 7. Configure MetalLB IP Address Pool
echo "\n🌐 Configuring MetalLB IP Address Pool..."

read -p "Enter the IP address range for MetalLB (e.g., 192.168.1.200-192.168.1.250): " METALLB_IP_RANGE
if [ -z "$METALLB_IP_RANGE" ]; then
    echo "❌ MetalLB IP address range is required"
    exit 1
fi

# Create a cluster-specific values override file
CLUSTER_VALUES_FILE="$REPO_ROOT/cluster-values.yaml"
cat > "$CLUSTER_VALUES_FILE" << EOF
metalLb:
  ipAddressPool:
    range: "$METALLB_IP_RANGE"
EOF

echo "✅ MetalLB IP Address Pool configured: $METALLB_IP_RANGE"
echo "📋 Configuration saved to: $CLUSTER_VALUES_FILE"

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
  git commit -m "Configure MetalLB IP Address Pool via cluster-entrypoint"
  git push origin main
  echo "\n✅ Changes pushed to main."
else
  echo "❌ Aborted by user. No changes committed."
  exit 1
fi

# Final CNI health check to ensure cluster networking is operational
echo "\n🔄 Performing final CNI health check..."
FINAL_ATTEMPTS=0
FINAL_MAX_ATTEMPTS=20
while [ $FINAL_ATTEMPTS -lt $FINAL_MAX_ATTEMPTS ]; do
  # Check if kubectl can communicate with the cluster and pods can be listed
  if kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -q "cilium\|calico\|flannel\|weave"; then
    CNI_READY=true
    # Check if there are any pods in ContainerCreating state for too long
    CONTAINER_CREATING_COUNT=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending -o json | jq '.items | length' 2>/dev/null || echo "0")
    if [ "$CONTAINER_CREATING_COUNT" -gt 5 ]; then  # More than 5 pods stuck in Pending is concerning
      CNI_READY=false
      echo "⚠️  Found $CONTAINER_CREATING_COUNT pods stuck in Pending state, waiting..."
    fi

    if [ "$CNI_READY" = true ]; then
      echo "✅ CNI appears healthy, all systems go!"
      break
    fi
  else
    echo "⏳ Waiting for CNI to be operational..."
  fi

  sleep 10
  FINAL_ATTEMPTS=$((FINAL_ATTEMPTS + 1))
done

if [ $FINAL_ATTEMPTS -eq $FINAL_MAX_ATTEMPTS ]; then
  echo "⚠️  Warning: Could not verify CNI health, but continuing anyway..."
else
  echo "✅ CNI is operational, installing required CRDs for infrastructure components..."

  # Install cert-manager CRDs (needed for certificates and cluster issuers)
  echo "📦 Installing cert-manager CRDs..."
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.1/cert-manager.crds.yaml || echo "⚠️ cert-manager CRDs may already be installed"

  # Install MetalLB CRDs only (needed for IPAddressPool and L2Advertisement)
  # Do not install the full MetalLB controller as that will be deployed by ArgoCD
  echo "📦 Installing MetalLB CRDs..."
  # Install each CRD individually since the combined metallb-crds.yaml might not exist
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.1/config/crd/bases/metallb.io_addresspools.yaml || echo "⚠️ MetalLB AddressPool CRD may already be installed"
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.1/config/crd/bases/metallb.io_l2advertisements.yaml || echo "⚠️ MetalLB L2Advertisement CRD may already be installed"
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.1/config/crd/bases/metallb.io_bgppeers.yaml || echo "⚠️ MetalLB BGPPeer CRD may already be installed"

  echo "✅ Required CRDs installed, infrastructure sync should proceed properly."
fi

echo "\n🔄 The cluster-init ArgoCD Application will now sync the infrastructure from Git."
echo "📊 Monitor sync status: kubectl get application cluster-init -n argocd"
echo "💡 ArgoCD UI: https://argocd.benedict-aryo.com"
echo "   The cluster-init application automatically manages all infrastructure via GitOps."
