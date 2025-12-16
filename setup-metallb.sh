#!/bin/bash
# Script to configure MetalLB and commit to Git

cd /root/k0s-cluster-bootstrap

# Create cluster-values.yaml directly
cat > cluster-values.yaml << EOF
metalLb:
  ipAddressPool:
    range: "192.168.1.240-192.168.1.250"
EOF

echo "✅ MetalLB IP Address Pool configured: 192.168.1.240-192.168.1.250"
echo "📋 Configuration saved to: /root/k0s-cluster-bootstrap/cluster-values.yaml"

# Add to git and commit
git add cluster-values.yaml
if [ -n "$(git status --porcelain)" ]; then
    git commit -m "Configure MetalLB IP Address Pool via cluster-entrypoint"
    git push origin main
    echo "✅ Changes pushed to main."
else
    echo "✅ No changes to commit."
fi

echo "🔄 The cluster-init ArgoCD Application should now be able to sync the infrastructure."