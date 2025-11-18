#!/bin/bash
set -e

# K0s Worker Installation Script
# This script installs and configures k0s as a worker node
# Designed for VPS/Homelab deployments (works behind CGNAT)

echo "🚀 K0s Worker Node Installation"
echo "================================"
echo ""
echo "This script will join this node to an existing k0s cluster."
echo "Works from anywhere - VPS, homelab, or behind CGNAT."
echo ""

# Interactive mode if no arguments provided
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "📋 Please provide the following information from your controller node:"
    echo ""
    
    # Get controller IP
    read -p "Enter controller node IP address (VPS public IP or local IP): " CONTROLLER_IP
    if [ -z "${CONTROLLER_IP}" ]; then
        echo "❌ Controller IP is required"
        exit 1
    fi
    
    # Get join token
    echo ""
    echo "Enter the join token (paste and press Enter):"
    read JOIN_TOKEN
    if [ -z "${JOIN_TOKEN}" ]; then
        echo "❌ Join token is required"
        exit 1
    fi
else
    CONTROLLER_IP="$1"
    JOIN_TOKEN="$2"
fi

echo ""
echo "📦 Configuration:"
echo "   Controller IP: ${CONTROLLER_IP}"
echo "   Token: ${JOIN_TOKEN:0:20}..."
echo ""

# Check prerequisites
echo "📋 Checking prerequisites..."
if ! command -v curl &> /dev/null; then
    echo "❌ curl is required but not installed. Installing..."
    sudo apt-get update && sudo apt-get install -y curl
fi

# Test connectivity to controller
echo "🔍 Testing connectivity to controller..."
if ! nc -zv -w 5 "${CONTROLLER_IP}" 6443 2>/dev/null; then
    echo "⚠️  Warning: Cannot connect to ${CONTROLLER_IP}:6443"
    echo "   This might be normal if controller has firewall rules."
    echo "   Continuing anyway..."
else
    echo "✅ Controller is reachable"
fi
echo ""

# Download k0s binary
echo "📦 Downloading k0s binary..."
curl -sSLf https://get.k0s.sh | sudo sh
echo "✅ K0s binary installed"
echo ""

# Install k0s worker with the provided token
echo "⚙️  Installing k0s worker service..."
echo "${JOIN_TOKEN}" | sudo k0s install worker --token-file -
echo "✅ K0s worker service configured"
echo ""

# Start k0s service
echo "🔄 Starting k0s worker service..."
sudo k0s start
echo "✅ K0s worker service started"
echo ""

# Wait a moment for service to initialize
echo "⏳ Waiting for worker to initialize..."
sleep 5

# Check status
echo "📊 Worker Status:"
sudo k0s status || true
echo ""

echo "========================================"
echo "✅ K0s Worker Installation Complete!"
echo "========================================"
echo ""
echo "📝 Verification Steps:"
echo "   1. On the controller node, run: kubectl get nodes"
echo "   2. You should see this worker node listed"
echo "   3. Wait 1-2 minutes for node to be Ready"
echo ""
echo "🔍 Useful Commands:"
echo "   Check status: sudo k0s status"
echo "   View logs: sudo journalctl -u k0sworker -f"
echo ""
echo "💡 Troubleshooting:"
echo "   If node doesn't appear:"
echo "   - Verify controller IP is correct (${CONTROLLER_IP})"
echo "   - Check firewall allows outbound to port 6443"
echo "   - Verify join token is still valid"
echo ""
