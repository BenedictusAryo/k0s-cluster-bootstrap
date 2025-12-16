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

# 5. Apply ArgoCD root Application manifest (cluster-init) - this will install Cilium via ArgoCD
APP_MANIFEST="$REPO_ROOT/cluster-init/cluster-init.yaml"
if [ -f "$APP_MANIFEST" ]; then
  echo "\n📦 Applying ArgoCD root Application (cluster-init)..."
  kubectl apply -f "$APP_MANIFEST"
  echo "✅ Applied $APP_MANIFEST"

  echo "⏳ Waiting for cluster-init ArgoCD application to be created..."
  sleep 10

  echo "🔄 Forcing hard sync of cluster-init application..."
  kubectl patch application cluster-init -n argocd --type merge -p '{"spec": {"syncPolicy": {"syncOptions": ["Prune=true", "Replace=true"]}}, "metadata": {"annotations": {"argocd.argoproj.io/sync": "true"}}}'
  echo "✅ Hard sync triggered"

  echo "⏳ Waiting for Cilium to be deployed (checking for cilium pods)..."
  ATTEMPTS=0
  MAX_ATTEMPTS=60  # Wait up to 15 minutes (60 attempts * 15s = 900s)
  while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    # Check for Cilium pods with the more common label selectors
    if kubectl get pods -n kube-system -l k8s-app=cilium-agent 2>/dev/null | grep -q "Running\|ContainerCreating" ||
       kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium 2>/dev/null | grep -q "Running\|ContainerCreating" ||
       kubectl get pods -n kube-system -l k8s-app=cilium 2>/dev/null | grep -q "Running\|ContainerCreating"; then
      echo "✅ Found Cilium pods, checking if they're ready..."

      # Check pods with different label selectors
      CILIUM_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium --no-headers 2>/dev/null | awk '{print $1}' ||
                    kubectl get pods -n kube-system -l k8s-app=cilium-agent --no-headers 2>/dev/null | awk '{print $1}' ||
                    kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | awk '{print $1}')

      if [ -n "$CILIUM_PODS" ]; then
        ALL_READY=true
        while IFS= read -r pod; do
          if [ -n "$pod" ]; then
            if ! kubectl get pod "$pod" -n kube-system -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null | grep -q "true\|false"; then
              # Pod might still be initializing
              ALL_READY=false
              break
            else
              POD_READY_STATUS=$(kubectl get pod "$pod" -n kube-system -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null)
              if echo "$POD_READY_STATUS" | grep -qv "true"; then
                ALL_READY=false
                break
              fi
            fi
          fi
        done <<< "$(echo "$CILIUM_PODS")"

        if [ "$ALL_READY" = true ]; then
          echo "✅ All Cilium pods are ready!"
          break
        fi
      fi
    else
      echo "⏳ Cilium pods not found yet ($((ATTEMPTS + 1))/$MAX_ATTEMPTS)"
    fi

    sleep 15
    ATTEMPTS=$((ATTEMPTS + 1))
  done

  if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
    echo "⚠️ Warning: Timeout waiting for Cilium to be ready via ArgoCD. Attempting direct Cilium installation..."

    # As a fallback, try installing Cilium directly if ArgoCD is taking too long
    echo "🔧 Attempting direct Cilium installation..."
    # Wait a bit more for any ongoing operations to settle
    sleep 30

    # Check again if Cilium is now running after ArgoCD had more time
    if kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium 2>/dev/null | grep -q "Running\|ContainerCreating" ||
       kubectl get pods -n kube-system -l k8s-app=cilium-agent 2>/dev/null | grep -q "Running\|ContainerCreating" ||
       kubectl get pods -n kube-system -l k8s-app=cilium 2>/dev/null | grep -q "Running\|ContainerCreating"; then
      echo "✅ Cilium found after additional wait - continuing..."
    else
      echo "🔧 Installing Cilium using cilium-cli..."
      cilium install --version 1.15.3 --namespace kube-system --reuse-values
      echo "⏳ Waiting for Cilium to become ready after direct installation..."
      kubectl wait --for=condition=ready pods -l k8s-app=cilium -n kube-system --timeout=300s || echo "⚠️ Cilium direct installation may not have completed successfully."
    fi
  else
    echo "✅ Cilium is ready, continuing with setup..."
  fi
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
fi

echo "\n🔄 The cluster-init ArgoCD Application will now sync the infrastructure from Git."
echo "📊 Monitor sync status: kubectl get application cluster-init -n argocd"
echo "💡 ArgoCD UI: https://argocd.benedict-aryo.com"
echo "   The cluster-init application automatically manages all infrastructure via GitOps."
