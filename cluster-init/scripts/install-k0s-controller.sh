#!/bin/bash
set -e

# K0s Controller Installation Script
# This script installs and configures k0s as a controller node
# Designed for VPS/Homelab deployments

echo "🚀 K0s Controller Node Installation"
echo "===================================="
echo ""

# Detect script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CONFIG_FILE="${SCRIPT_DIR}/../config/k0s.yaml"

# Check prerequisites
echo "📋 Checking prerequisites..."
if ! command -v curl &> /dev/null; then
    echo "❌ curl is required but not installed. Installing..."
    sudo apt-get update && sudo apt-get install -y curl
fi

# Get server IP for display
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "✅ Controller node IP: ${SERVER_IP}"
echo ""

# Download k0s binary
echo "📦 Downloading k0s binary..."
curl -sSLf https://get.k0s.sh | sudo sh
echo "✅ K0s binary installed"
echo ""

# Create k0s config directory
sudo mkdir -p /etc/k0s

# Check if config file exists and copy it
if [ -f "${CONFIG_FILE}" ]; then
    echo "📝 Using custom k0s configuration from ${CONFIG_FILE}"
    sudo cp "${CONFIG_FILE}" /etc/k0s/k0s.yaml
    
    # Prompt for VPS public IP if different from local IP
    echo ""
    echo "⚙️  Configuration Setup"
    echo "Current detected IP: ${SERVER_IP}"
    read -p "Enter VPS public IP (or press Enter to use ${SERVER_IP}): " PUBLIC_IP
    PUBLIC_IP=${PUBLIC_IP:-$SERVER_IP}
    
    # Add public IP to SANs if provided
    if [ ! -z "${PUBLIC_IP}" ] && [ "${PUBLIC_IP}" != "${SERVER_IP}" ]; then
        echo "Adding ${PUBLIC_IP} to API server SANs..."
        sudo sed -i "/sans:/a\      - ${PUBLIC_IP}" /etc/k0s/k0s.yaml
    fi
    
    # Ask about cluster topology
    echo ""
    echo "🤔 Cluster Configuration"
    echo "1) Single-node cluster (controller + worker, no additional nodes planned)"
    echo "2) Multi-node cluster with controller also running workloads"
    echo "3) Multi-node cluster with controller dedicated (no workloads on controller)"
    read -p "Select cluster type [1/2/3] (default: 1): " CLUSTER_TYPE
    CLUSTER_TYPE=${CLUSTER_TYPE:-1}
    
    case "$CLUSTER_TYPE" in
        1)
            echo "✅ Installing as single-node cluster (controller + worker)"
            ENABLE_WORKER="Y"
            REMOVE_TAINT="Y"
            sudo k0s install controller --enable-worker --config /etc/k0s/k0s.yaml
            ;;
        2)
            echo "✅ Installing as multi-node cluster with controller running workloads"
            ENABLE_WORKER="Y"
            REMOVE_TAINT="Y"
            sudo k0s install controller --enable-worker --config /etc/k0s/k0s.yaml
            ;;
        3)
            echo "✅ Installing as controller-only (dedicated, no workloads)"
            ENABLE_WORKER="N"
            REMOVE_TAINT="N"
            sudo k0s install controller --config /etc/k0s/k0s.yaml
            ;;
        *)
            echo "⚠️  Invalid selection, defaulting to single-node cluster"
            ENABLE_WORKER="Y"
            REMOVE_TAINT="Y"
            sudo k0s install controller --enable-worker --config /etc/k0s/k0s.yaml
            ;;
    esac
else
    echo "⚠️  Custom config not found, using default configuration"
    
    # Ask about cluster topology
    echo ""
    echo "🤔 Cluster Configuration"
    echo "1) Single-node cluster (controller + worker, no additional nodes planned)"
    echo "2) Multi-node cluster with controller also running workloads"
    echo "3) Multi-node cluster with controller dedicated (no workloads on controller)"
    read -p "Select cluster type [1/2/3] (default: 1): " CLUSTER_TYPE
    CLUSTER_TYPE=${CLUSTER_TYPE:-1}
    
    case "$CLUSTER_TYPE" in
        1)
            echo "✅ Installing as single-node cluster (controller + worker)"
            ENABLE_WORKER="Y"
            REMOVE_TAINT="Y"
            sudo k0s install controller --enable-worker
            ;;
        2)
            echo "✅ Installing as multi-node cluster with controller running workloads"
            ENABLE_WORKER="Y"
            REMOVE_TAINT="Y"
            sudo k0s install controller --enable-worker
            ;;
        3)
            echo "✅ Installing as controller-only (dedicated, no workloads)"
            ENABLE_WORKER="N"
            REMOVE_TAINT="N"
            sudo k0s install controller
            ;;
        *)
            echo "⚠️  Invalid selection, defaulting to single-node cluster"
            ENABLE_WORKER="Y"
            REMOVE_TAINT="Y"
            sudo k0s install controller --enable-worker
            ;;
    esac
fi

echo ""
echo "🔄 Starting k0s service..."
sudo k0s start

# Wait for k0s to be ready
echo "⏳ Waiting for k0s to be ready (this may take 30-60 seconds)..."
sleep 10

# Wait for API server
retries=0
max_retries=30
while ! sudo k0s kubectl get nodes &>/dev/null; do
    retries=$((retries+1))
    if [ $retries -gt $max_retries ]; then
        echo "❌ Timeout waiting for API server"
        echo "Check logs with: sudo journalctl -u k0scontroller -f"
        exit 1
    fi
    echo "  Waiting for API server... ($retries/$max_retries)"
    sleep 5
done

echo "✅ K0s API server is ready"
echo ""

# Set up kubeconfig
echo "🔑 Setting up kubeconfig..."
mkdir -p ~/.kube
sudo k0s kubeconfig admin > ~/.kube/config
chmod 600 ~/.kube/config
echo "✅ Kubeconfig saved to ~/.kube/config"
echo ""

# Remove control-plane taint if needed
if [[ "$REMOVE_TAINT" == "Y" ]]; then
    echo "🔓 Removing control-plane taint (controller will run workloads)..."

    # Wait a bit for node to be fully ready
    sleep 5

    # Get the node name (usually "localhost" for k0s single-node)
    NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "localhost")

    echo "   Removing taint from node: $NODE_NAME"
    kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true

    # Verify taint removal
    if kubectl get nodes "$NODE_NAME" -o jsonpath='{.spec.taints}' | grep -q "control-plane"; then
        echo "⚠️  Taint may still be present. You can manually remove it with:"
        echo "    kubectl taint nodes $NODE_NAME node-role.kubernetes.io/control-plane:NoSchedule-"
    else
        echo "✅ Control-plane taint removed - workloads can now schedule on controller"
    fi
    echo ""
else
    echo "ℹ️  Controller node will NOT run workloads (taint preserved)"
    echo "   Add worker nodes using the join token below"
    echo ""
fi

# Generate worker join token
echo "🎫 Generating worker join token..."
JOIN_TOKEN=$(sudo k0s token create --role=worker)
echo ""
echo "========================================"
echo "✅ K0s Controller Installation Complete!"
echo "========================================"
echo ""
echo "📊 Cluster Status:"
sudo k0s kubectl get nodes
echo ""
echo "🔗 Worker Join Information:"
echo "   Controller IP: ${PUBLIC_IP:-$SERVER_IP}"
echo "   Controller Port: 6443"
echo ""
echo "🎫 Worker Join Token (save this for worker nodes):"
echo "${JOIN_TOKEN}"
echo ""
echo "📝 Next Steps:"
echo "   1. Save the join token above"
echo "   2. Run ./setup-argocd.sh to install ArgoCD"
echo "   3. On worker nodes, run: ./install-k0s-worker.sh"
echo ""
echo "🔍 Useful Commands:"
echo "   Check status: sudo k0s status"
echo "   View logs: sudo journalctl -u k0scontroller -f"
echo "   Get nodes: kubectl get nodes"
echo ""
