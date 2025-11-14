#!/bin/bash
set -e

# ArgoCD Setup Script
# This script deploys ArgoCD and the cluster bootstrap application

echo "Setting up ArgoCD..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "kubectl not found. Please ensure k0s is installed and kubeconfig is configured."
    exit 1
fi

# Create ArgoCD namespace
echo "Creating ArgoCD namespace..."
kubectl apply -f ../manifests/argocd/namespace.yaml

# Install ArgoCD
echo "Installing ArgoCD..."
kubectl apply -f ../manifests/argocd/argocd-install.yaml

# Wait for ArgoCD to be ready
echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Deploy cluster bootstrap application
echo "Deploying cluster bootstrap application..."
kubectl apply -f ../manifests/argocd/cluster-bootstrap-app.yaml

# Get ArgoCD admin password
echo ""
echo "ArgoCD setup completed!"
echo ""
echo "ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""
echo ""
echo "To access ArgoCD UI, run:"
echo "kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "Then visit: https://localhost:8080"
