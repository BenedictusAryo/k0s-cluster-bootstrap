#!/bin/bash
set -e

echo "=== 🚀 Installing Prerequisites for K0s GitOps Serverless Platform ==="
echo ""

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo "⚠️  This script requires root privileges. Running with sudo..."
    exec sudo -E bash "$0" "$@"
fi

# Track installed components
COMPONENTS_INSTALLED=()

# --- Install System Dependencies ---
echo "--- 1/8: Installing System Dependencies ---"
if [ -f /etc/debian_version ]; then
    # Ubuntu/Debian
    apt-get update -qq
    apt-get install -y -qq \
        curl wget jq git \
        apt-transport-https ca-certificates gnupg lsb-release \
        linux-headers-$(uname -r) \
        apparmor apparmor-utils \
        conntrack ipvsadm
    
    # Enable required kernel modules for Cilium
    modprobe -a br_netfilter ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack

    # Make kernel modules persistent
    cat <<EOF > /etc/modules-load.d/cilium.conf
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

    # Configure sysctl for Kubernetes
    cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 1000000
EOF
    sysctl --system

elif [ -f /etc/redhat-release ]; then
    # RHEL/CentOS/Fedora
    dnf install -y -q \
        curl wget jq git \
        yum-utils device-mapper-persistent-data lvm2 \
        kernel-headers-$(uname -r) \
        apparmor-utils \
        conntrack-tools ipvsadm
    
    # Enable required kernel modules for Cilium
    modprobe -a br_netfilter ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack

    # Make kernel modules persistent
    cat <<EOF > /etc/modules-load.d/cilium.conf
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

    # Configure sysctl for Kubernetes
    cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.netfilter.nf_conntrack_max = 1000000
EOF
    sysctl --system

else
    echo "⚠️  Unsupported Linux distribution. Please install dependencies manually."
    echo "Required packages: curl, wget, jq, git, linux-headers, apparmor, conntrack, ipvsadm"
fi

COMPONENTS_INSTALLED+=("System Dependencies")
echo "✅ System dependencies installed."
echo ""

# --- Install k0s ---
echo "--- 2/8: Installing k0s ---"
if ! command -v k0s &> /dev/null; then
    curl -sSLf https://get.k0s.sh | sh
    COMPONENTS_INSTALLED+=("k0s")
    echo "✅ k0s installed (version: $(k0s version))."
else
    echo "✅ k0s is already installed (version: $(k0s version))."
fi
echo ""

# --- Install kubectl (K8s CLI) ---
echo "--- 3/8: Installing kubectl ---"
if ! command -v kubectl &> /dev/null; then
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    COMPONENTS_INSTALLED+=("kubectl")
    echo "✅ kubectl installed (version: ${KUBECTL_VERSION})."
else
    echo "✅ kubectl is already installed (version: $(kubectl version --client --short 2>/dev/null || kubectl version --client))."
fi
echo ""

# --- Install Helm (K8s Package Manager) ---
echo "--- 4/8: Installing Helm ---"
if ! command -v helm &> /dev/null; then
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh --version v3.13.0
    rm get_helm.sh
    COMPONENTS_INSTALLED+=("Helm")
    echo "✅ Helm installed (version: $(helm version --short))."
else
    echo "✅ Helm is already installed (version: $(helm version --short))."
fi
echo ""

# --- Install Cilium CLI ---
echo "--- 5/8: Installing Cilium CLI ---"
if ! command -v cilium &> /dev/null; then
    CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    CLI_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
    curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
    tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
    rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
    COMPONENTS_INSTALLED+=("Cilium CLI")
    echo "✅ Cilium CLI installed (version: $(cilium version --client))."
else
    echo "✅ Cilium CLI is already installed (version: $(cilium version --client))."
fi
echo ""

# --- Install kubeseal (Sealed Secrets) ---
echo "--- 6/8: Installing kubeseal ---"
if ! command -v kubeseal &> /dev/null; then
    echo "Fetching latest kubeseal version..."
    # Get latest release tag properly
    if command -v jq &> /dev/null; then
        KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | jq -r '.tag_name' | sed 's/^v//')
    else
        KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")' | tr -d '"' | sed 's/^v//')
    fi
    
    CLI_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
    
    OS_NAME="linux"
    if [ "$(uname)" = "Darwin" ]; then OS_NAME="darwin"; fi
    
    echo "Downloading kubeseal version ${KUBESEAL_VERSION} for ${OS_NAME}-${CLI_ARCH}..."
    
    # Create temp directory
    TMP_DIR=$(mktemp -d)
    
    # CORRECTED FILENAME FORMAT: kubeseal-${VERSION}-${OS}-${ARCH}.tar.gz
    FILENAME="kubeseal-${KUBESEAL_VERSION}-${OS_NAME}-${CLI_ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/${FILENAME}"
    
    echo "Trying URL: ${DOWNLOAD_URL}"
    
    # Download the file
    if curl -L --fail --silent --show-error -o "${TMP_DIR}/${FILENAME}" "${DOWNLOAD_URL}"; then
        echo "✅ Download successful"
    else
        echo "❌ Download failed. Checking available assets..."
        curl -s "https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/tags/v${KUBESEAL_VERSION}" | jq -r '.assets[].name' 2>/dev/null || true
        rm -rf "${TMP_DIR}"
        exit 1
    fi
    
    # Check if file exists and is not empty
    if [ ! -s "${TMP_DIR}/${FILENAME}" ]; then
        echo "❌ ERROR: Downloaded file is empty"
        rm -rf "${TMP_DIR}"
        exit 1
    fi
    
    # Extract the binary
    echo "📦 Extracting kubeseal binary..."
    tar xzvf "${TMP_DIR}/${FILENAME}" -C "${TMP_DIR}" kubeseal
    
    # Check if binary was extracted
    if [ ! -f "${TMP_DIR}/kubeseal" ]; then
        echo "❌ ERROR: kubeseal binary not found in archive"
        echo "Contents of archive:"
        tar -tzvf "${TMP_DIR}/${FILENAME}"
        rm -rf "${TMP_DIR}"
        exit 1
    fi
    
    # Install the binary
    install -o root -g root -m 0755 "${TMP_DIR}/kubeseal" /usr/local/bin/
    
    # Clean up
    rm -rf "${TMP_DIR}"
    
    COMPONENTS_INSTALLED+=("kubeseal")
    echo "✅ kubeseal installed (version: $(kubeseal --version))."
else
    echo "✅ kubeseal is already installed (version: $(kubeseal --version))."
fi
echo ""

# --- Install cloudflared (Cloudflare Tunnel) - FIXED FOR UBUNTU 24.04 ---
echo "--- 7/8: Installing cloudflared ---"
if ! command -v cloudflared &> /dev/null; then
    if [ -f /etc/debian_version ]; then
        # Ubuntu/Debian - FIXED REPOSITORY SETUP WITH FALLBACK
        echo "📦 Setting up Cloudflare repository for Debian/Ubuntu..."
        
        # Install required packages
        apt-get update -qq
        apt-get install -y -qq software-properties-common curl
        
        # Get distribution name
        DISTRO=$(lsb_release -cs)
        
        # Map unsupported distros to closest supported version
        case "$DISTRO" in
            "noble"|"mantic"|"lunar")
                # Ubuntu 24.04/23.10/23.04 - use jammy (22.04) repo
                CLOUDFLARE_DISTRO="jammy"
                echo "ℹ️  Ubuntu $DISTRO detected - using jammy (22.04) repository"
                ;;
            "jammy"|"focal"|"bionic")
                # Supported Ubuntu versions
                CLOUDFLARE_DISTRO="$DISTRO"
                ;;
            "bookworm"|"bullseye"|"buster")
                # Supported Debian versions
                CLOUDFLARE_DISTRO="$DISTRO"
                ;;
            *)
                # Unknown/unsupported - try binary install instead
                echo "⚠️  Unsupported distribution: $DISTRO - falling back to binary installation"
                CLOUDFLARE_DISTRO=""
                ;;
        esac
        
        if [ -n "$CLOUDFLARE_DISTRO" ]; then
            # Add Cloudflare GPG key
            mkdir -p /usr/share/keyrings
            curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare.gpg
            
            # Add repository based on distribution family
            if [[ "$DISTRO" =~ ^(noble|mantic|lunar|jammy|focal|bionic)$ ]]; then
                # Ubuntu family
                echo "deb [signed-by=/usr/share/keyrings/cloudflare.gpg] https://pkg.cloudflare.com/cloudflared/ubuntu/ $CLOUDFLARE_DISTRO main" | tee /etc/apt/sources.list.d/cloudflare-cloudflared.list >/dev/null
            else
                # Debian family
                echo "deb [signed-by=/usr/share/keyrings/cloudflare.gpg] https://pkg.cloudflare.com/cloudflared/debian/ $CLOUDFLARE_DISTRO main" | tee /etc/apt/sources.list.d/cloudflare-cloudflared.list >/dev/null
            fi
            
            # Update package lists and install
            if apt-get update -qq 2>/dev/null && apt-get install -y -qq cloudflared 2>/dev/null; then
                echo "✅ Cloudflare repository configured and cloudflared installed."
            else
                echo "⚠️  Repository installation failed - falling back to binary installation"
                CLOUDFLARE_DISTRO=""
            fi
        fi
        
        # Fallback to binary installation if repo method failed
        if [ -z "$CLOUDFLARE_DISTRO" ] || ! command -v cloudflared &> /dev/null; then
            echo "📦 Installing cloudflared from binary..."
            
            ARCH=$(uname -m)
            if [[ "$ARCH" == "x86_64" ]]; then
                ARCH="amd64"
            elif [[ "$ARCH" == "aarch64" ]]; then
                ARCH="arm64"
            fi
            
            TMP_DIR=$(mktemp -d)
            curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o "${TMP_DIR}/cloudflared"
            chmod +x "${TMP_DIR}/cloudflared"
            install -o root -g root -m 0755 "${TMP_DIR}/cloudflared" /usr/local/bin/
            rm -rf "${TMP_DIR}"
            
            echo "✅ cloudflared installed from binary."
        fi
        
    elif [ -f /etc/redhat-release ]; then
        # RHEL/CentOS/Fedora
        echo "📦 Setting up Cloudflare repository for RHEL/CentOS/Fedora..."
        
        # Install Cloudflare repository RPM
        dnf install -y -q https://pkg.cloudflare.com/cloudflare-release-el$(rpm -E %rhel).rpm
        
        # Install cloudflared
        dnf install -y -q cloudflared
        
        echo "✅ Cloudflare repository configured and cloudflared installed."
        
    else
        # Generic Linux install
        echo "📦 Installing cloudflared from binary (generic Linux)..."
        
        ARCH=$(uname -m)
        if [[ "$ARCH" == "x86_64" ]]; then
            ARCH="amd64"
        elif [[ "$ARCH" == "aarch64" ]]; then
            ARCH="arm64"
        fi
        
        TMP_DIR=$(mktemp -d)
        curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o "${TMP_DIR}/cloudflared"
        chmod +x "${TMP_DIR}/cloudflared"
        install -o root -g root -m 0755 "${TMP_DIR}/cloudflared" /usr/local/bin/
        rm -rf "${TMP_DIR}"
        
        echo "✅ cloudflared installed from binary."
    fi
    
    COMPONENTS_INSTALLED+=("cloudflared")
    echo "✅ cloudflared installed (version: $(cloudflared --version | head -1))."
else
    echo "✅ cloudflared is already installed (version: $(cloudflared --version | head -1))."
fi
echo ""

# --- Install ArgoCD CLI ---
echo "--- 8/8: Installing ArgoCD CLI ---"
if ! command -v argocd &> /dev/null; then
    ARGOCD_VERSION=$(curl -s https://api.github.com/repos/argoproj/argo-cd/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")' | tr -d '"')
    CLI_ARCH=amd64
    if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
    curl -L "https://github.com/argoproj/argo-cd/releases/download/v${ARGOCD_VERSION}/argocd-linux-${CLI_ARCH}" -o argocd
    chmod +x argocd
    install -o root -g root -m 0755 argocd /usr/local/bin/
    rm argocd
    COMPONENTS_INSTALLED+=("ArgoCD CLI")
    echo "✅ ArgoCD CLI installed (version: $(argocd version --client --short))."
else
    echo "✅ ArgoCD CLI is already installed (version: $(argocd version --client --short))."
fi
echo ""

# --- Verify Linux Kernel Version for Cilium ---
echo "--- Verifying Linux Kernel Version ---"
KERNEL_VERSION=$(uname -r)
MIN_KERNEL="5.4.0"
if [ "$(printf '%s\n' "$MIN_KERNEL" "$KERNEL_VERSION" | sort -V | head -n1)" = "$MIN_KERNEL" ]; then
    echo "✅ Kernel version ${KERNEL_VERSION} is sufficient for Cilium."
else
    echo "⚠️  WARNING: Kernel version ${KERNEL_VERSION} may not be optimal for Cilium."
    echo "    For best performance and feature support, Linux kernel 5.4+ is recommended."
    echo "    Some Cilium features may be limited on your current kernel version."
fi
echo ""

# --- Summary ---
echo "=== 🎉 All prerequisites installation complete! ==="
echo ""
echo "Installed components:"
for component in "${COMPONENTS_INSTALLED[@]}"; do
    echo "  • ${component}"
done
echo ""
echo "System status:"
echo "  • Kubernetes CLI: $(kubectl version --client --short 2>/dev/null || echo 'not available')"
echo "  • k0s version: $(k0s version 2>/dev/null || echo 'not available')"
echo "  • Helm version: $(helm version --short 2>/dev/null || echo 'not available')"
echo "  • Cilium CLI: $(cilium version --client 2>/dev/null || echo 'not available')"
echo "  • kubeseal: $(kubeseal --version 2>/dev/null || echo 'not available')"
echo "  • cloudflared: $(cloudflared --version 2>/dev/null | head -1 || echo 'not available')"
echo "  • ArgoCD CLI: $(argocd version --client --short 2>/dev/null || echo 'not available')"
echo "  • Linux Kernel: ${KERNEL_VERSION}"
echo ""

echo "=== 📋 Next Steps ==="
echo ""
echo "1. For controller node:"
echo "   cd cluster-bootstrap"
echo "   ./scripts/install-k0s-controller.sh"
echo ""
echo "2. For worker nodes:"
echo "   cd cluster-bootstrap"
echo "   ./scripts/install-k0s-worker.sh"
echo ""
echo "3. After cluster setup:"
echo "   ./scripts/setup-argocd.sh"
echo ""
echo "4. Configure Cloudflare Tunnel:"
echo "   - Create tunnel in Cloudflare dashboard"
echo "   - Generate sealed secrets using scripts/generate-sealed-secrets.sh"
echo ""
echo "💡 Tips:"
echo "   - Ensure your firewall allows K0s communication (TCP 6443, 9090, 8132, 8443)"
echo "   - For production, consider setting up etcd backup and monitoring"
echo "   - All cluster configuration will be managed via GitOps after setup"
echo ""

echo "Ready to deploy your GitOps-powered serverless platform! 🚀"