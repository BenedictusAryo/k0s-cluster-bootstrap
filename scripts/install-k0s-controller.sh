#!/bin/bash
set -e

# K0s Controller Installation Script
# This script installs and configures k0s as a controller node

echo "Installing k0s controller..."

# Download k0s binary
curl -sSLf https://get.k0s.sh | sudo sh

# Check if config file exists
if [ -f ../config/k0s.yaml ]; then
    echo "Using custom k0s configuration..."
    sudo k0s install controller --config ../config/k0s.yaml
else
    echo "Using default k0s configuration..."
    sudo k0s install controller
fi

# Start k0s service
sudo k0s start

# Wait for k0s to be ready
echo "Waiting for k0s to be ready..."
sleep 10

# Get kubeconfig
sudo k0s kubeconfig admin > ~/.kube/config || mkdir -p ~/.kube && sudo k0s kubeconfig admin > ~/.kube/config

echo "K0s controller installation completed!"
echo "You can check the status with: sudo k0s status"
