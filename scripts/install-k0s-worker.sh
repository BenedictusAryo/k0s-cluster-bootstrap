#!/bin/bash
set -e

# K0s Worker Installation Script
# This script installs and configures k0s as a worker node

if [ -z "$1" ]; then
    echo "Usage: $0 <join-token>"
    echo "Please provide the join token from the controller node"
    exit 1
fi

JOIN_TOKEN="$1"

echo "Installing k0s worker..."

# Download k0s binary
curl -sSLf https://get.k0s.sh | sudo sh

# Install k0s worker with the provided token
echo "$JOIN_TOKEN" | sudo k0s install worker --token-file -

# Start k0s service
sudo k0s start

echo "K0s worker installation completed!"
echo "You can check the status with: sudo k0s status"
