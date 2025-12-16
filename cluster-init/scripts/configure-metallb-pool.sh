#!/bin/bash
set -e

# Script to configure MetalLB IP address pool
# This script configures the MetalLB IP range using the values file approach

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

echo "🌐 Configuring MetalLB IP Address Pool..."

read -p "Enter the IP address range for MetalLB (e.g., 192.168.1.200-192.168.1.250): " METALLB_IP_RANGE
if [ -z "$METALLB_IP_RANGE" ]; then
    echo "❌ MetalLB IP address range is required"
    exit 1
fi

# Create a cluster-specific values override file (same approach as cluster-entrypoint.sh)
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
if [ -n "$ALL_CHANGES" ]; then
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
    git commit -m "Configure MetalLB IP Address Pool via values file"
    git push origin main
    echo "\n✅ Changes pushed to main."
  else
    echo "❌ Aborted by user. Changes not committed."
    exit 1
  fi
else
  echo "✅ No changes detected."
fi

echo "\n🔄 The cluster-init ArgoCD Application will now sync the MetalLB configuration from Git."
echo "📊 Monitor sync status: kubectl get application cluster-init -n argocd"