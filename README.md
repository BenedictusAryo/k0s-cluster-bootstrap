# k0s-cluster-bootstrap

GitOps-powered Kubernetes cluster bootstrap for **VPS/Homelab** deployments using [k0s](https://k0sproject.io/), [ArgoCD](https://argo-cd.readthedocs.io/), and [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets).

> 🏡 **Perfect for homelab behind CGNAT or VPS deployments**
> 
> This setup works great with:
> - VPS hosting (DigitalOcean, Hetzner, Linode, etc.)
> - Homelab servers behind CGNAT (no port forwarding needed!)
> - Hybrid setups (VPS controller + homelab workers)
> - Single-node or multi-node clusters

## 💡 Why This Setup?

**Traditional Kubernetes challenges**:
- ❌ Requires static public IP
- ❌ Complex port forwarding setup
- ❌ Manual SSL certificate management
- ❌ Doesn't work behind CGNAT
- ❌ Heavy resource requirements

**Our solution**:
- ✅ Works behind CGNAT with Cloudflare Tunnel
- ✅ No inbound ports needed
- ✅ Automatic SSL via Cloudflare
- ✅ GitOps-based deployment
- ✅ Lightweight k0s (50-70% less resources than full K8s)
- ✅ Add worker nodes from anywhere

## 📚 Prerequisites

### For Controller Node (VPS recommended)
- **OS**: Ubuntu 22.04 LTS / Debian 11+ / RHEL 8+
- **CPU**: 4 cores (vCPU)
- **RAM**: 8 GB
- **Storage**: 100 GB SSD
- **Network**: Public IP or stable connection
- **Kernel**: Linux 5.4+ (for eBPF support)

### For Worker Nodes (VPS or Homelab)
- **OS**: Ubuntu 22.04 LTS / Debian 11+ / RHEL 8+
- **CPU**: 4 cores
- **RAM**: 8 GB
- **Storage**: 50 GB SSD
- **Network**: Outbound internet access (works behind CGNAT!)

### External Requirements
- Domain managed in Cloudflare DNS (e.g., `benedict-aryo.com`)
- Git repository for GitOps (this repo)
- sudo privileges on all nodes

## 🏛️ Architecture

```mermaid
graph TB
    Internet[Internet Users] -->|HTTPS| CF[Cloudflare Edge]
    CF -.->|Tunnel| VPS[VPS Controller<br/>K0s + ArgoCD]
    CF -.->|Tunnel| HL1[Homelab Worker 1]
    CF -.->|Tunnel| HL2[Homelab Worker 2]
    
    HL1 -.->|Join 6443| VPS
    HL2 -.->|Join 6443| VPS
    
    style CF fill:#f39c12
    style VPS fill:#3498db
    style HL1 fill:#2ecc71
    style HL2 fill:#2ecc71
```

## 📊 Project Structure

```
cluster-bootstrap/
├── scripts/
│   ├── install-k0s-controller.sh  # Install k0s controller node
│   ├── install-k0s-worker.sh      # Install k0s worker node
│   └── setup-argocd.sh            # Deploy ArgoCD
├── manifests/
│   ├── argocd/
│   │   ├── namespace.yaml                # ArgoCD namespace
│   │   ├── argocd-install.yaml          # ArgoCD configuration
│   │   └── cluster-bootstrap-app.yaml   # Bootstrap application
│   └── sealed-secrets/
│       ├── controller.yaml              # Sealed Secrets controller
│       └── secrets/
│           └── *-sealed.yaml            # Sealed secrets (safe to commit!)
├── config/
│   └── k0s.yaml                         # K0s cluster configuration
├── secrets/
│   └── examples/
│       └── cloudflare-secret.example    # Example secret template
└── README.md
```

## 🚀 Quick Start

### 🎯 Deployment Scenarios

Choose your deployment scenario:

#### Scenario 1: VPS-Only (Simplest)
Perfect for getting started quickly with a single VPS or multiple VPS nodes.

#### Scenario 2: Hybrid VPS + Homelab (Recommended)
VPS controller for stability + homelab workers for cost savings. Works great behind CGNAT!

#### Scenario 3: Pure Homelab
All nodes in homelab (requires one node with stable connection for controller).

---

### 📦 Installation Steps

#### Step 1: Install Prerequisites (All Nodes)

On **every** node (controller and workers):

```bash
git clone https://github.com/BenedictusAryo/k0s-cluster-bootstrap.git
cd k0s-cluster-bootstrap/scripts
chmod +x *.sh
./install-prerequisites.sh
./install-k0s-controller.sh
```

This will:
- Download and install k0s
- Configure the controller using `config/k0s.yaml`
- Start the k0s service
- Generate kubeconfig file

### Step 2: Add Worker Nodes (Optional)

First, generate a join token on the controller:

```bash
sudo k0s token create --role=worker
```

Then, on each worker node:

```bash
cd scripts
./install-k0s-worker.sh <join-token>
```

### Step 3: Set up ArgoCD

On the controller node (or any machine with kubectl access):

```bash
cd scripts
./setup-argocd.sh
```

This will:
- Create the ArgoCD namespace
- Deploy ArgoCD
- Deploy the cluster bootstrap application
- Display the admin password

### Step 4: Access ArgoCD UI

Forward the ArgoCD server port:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Access the UI at `https://localhost:8080`

- Username: `admin`
- Password: (displayed after running setup-argocd.sh)

## 🔐 Secret Management

This repository uses Sealed Secrets to securely store secrets in Git.

### Installing kubeseal CLI

```bash
# Linux
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-linux-amd64.tar.gz
tar xfz kubeseal-0.24.0-linux-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal

# macOS
brew install kubeseal
```

### Creating Sealed Secrets

1. Create your secret file (use the example as a template):

```bash
cp secrets/examples/cloudflare-secret.example secrets/my-secret.yaml
# Edit the file with your actual values
```

2. Seal the secret:

```bash
kubeseal --format=yaml < secrets/my-secret.yaml > secrets/my-sealed-secret.yaml
```

3. Apply the sealed secret:

```bash
kubectl apply -f secrets/my-sealed-secret.yaml
```

4. Commit only the sealed secret to Git (never commit the unsealed version)

### Setting up Cloudflare Tunnel (Required for App Access)

Cloudflare Tunnel provides secure access to your applications without exposing ports to the internet.

#### Step 1: Create Cloudflare Tunnel

1. Log in to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/)
2. Navigate to **Networks** → **Tunnels**
3. Click **Create a tunnel**
4. Choose **Cloudflared** as the connector type
5. Name your tunnel (e.g., `k0s-cluster-tunnel`)
6. Copy the tunnel token (starts with `eyJh...`)

#### Step 2: Create Kubernetes Secret

**IMPORTANT**: Deploy the tunnel **inside Kubernetes**, not as a system service. This ensures it works across all deployment scenarios (VPS, Hybrid, Homelab).

```bash
# Create the cloudflare-tunnel namespace
kubectl create namespace cloudflare-tunnel

# Create and seal the secret in one step (no plain secret stored!)
kubectl create secret generic cloudflare-tunnel-secret \
  --from-literal=tunnel-token="eyJhIjoiMDJkYjBlMDJjODNiMjg0MGIyZWM3NGM4MjAxNWQ1YW..." \
  -n cloudflare-tunnel \
  --dry-run=client -o yaml | \
  kubeseal --controller-name=sealed-secrets --controller-namespace=kube-system \
  -o yaml > manifests/sealed-secrets/secrets/cloudflare-tunnel-sealed.yaml

# Apply the sealed secret
kubectl apply -f manifests/sealed-secrets/secrets/cloudflare-tunnel-sealed.yaml

# Verify the secret was created
kubectl get secret cloudflare-tunnel-secret -n cloudflare-tunnel
```

**Note**: Sealed secrets are **safe to commit to Git**! They're encrypted and can only be decrypted by your cluster's Sealed Secrets Controller.

#### Step 3: Find Service Names for Routing

Before configuring Cloudflare routes, you need to find the internal Kubernetes service names:

```bash
# List all services to find service names
kubectl get svc -A

# Get specific service details
kubectl get svc -n argocd
kubectl get svc -n kourier-system
kubectl get svc -n observability
```

**Understanding Kubernetes DNS format:**
```
<service-name>.<namespace>.svc.cluster.local:<port>

Examples:
- argocd-server.argocd.svc.cluster.local:443
- kourier.kourier-system.svc.cluster.local:80
- jaeger-query.observability.svc.cluster.local:16686
```

**Key services in this setup:**
- **ArgoCD**: Service `argocd-server` in namespace `argocd`, port `443`
- **Kourier**: Service `kourier` in namespace `kourier-system`, port `80`
- **Jaeger**: Service `jaeger-query` in namespace `observability`, port `16686`

#### Step 4: Configure Public Hostnames

In the Cloudflare Zero Trust Dashboard, configure your tunnel routes:

1. **ArgoCD** (for GitOps management):
   - Subdomain: `argocd`
   - Domain: `your-domain.com`
   - Service Type: `HTTPS`
   - URL: `argocd-server.argocd.svc.cluster.local:443`
   - Additional settings → TLS → Enable **"No TLS Verify"** ✅
   
   **Why "No TLS Verify"?** ArgoCD uses self-signed certificates internally. This setting tells Cloudflare Tunnel to trust the internal certificate. Your traffic is still encrypted end-to-end.

2. **Jaeger** (optional, for observability):
   - Subdomain: `jaeger`
   - Domain: `your-domain.com`
   - Service Type: `HTTP`
   - URL: `jaeger-query.observability.svc.cluster.local:16686`

3. **Knative Services** (wildcard for all apps):
   - Subdomain: `*` (wildcard)
   - Domain: `your-domain.com`
   - Service Type: `HTTP`
   - URL: `kourier.kourier-system.svc.cluster.local:80`

4. **Catch-all rule**: `http_status:404`

**Important Notes**:
- ⚠️ **Route Order Matters**: Place specific routes (argocd, jaeger) BEFORE the wildcard route
- ✅ The wildcard route handles all Knative services (e.g., `hello.your-domain.com`, `api.your-domain.com`)
- ✅ These URLs use Kubernetes internal DNS - they only work from inside the cluster (where the tunnel pod runs)

#### Step 5: Create DNS Records

In the Cloudflare DNS dashboard (not Zero Trust):

1. Add CNAME record for ArgoCD:
   - **Type**: `CNAME`
   - **Name**: `argocd`
   - **Target**: `<your-tunnel-id>.cfargotunnel.com` (find this in your tunnel settings)
   - **Proxy status**: ✅ Proxied (orange cloud)

2. Add CNAME record for Jaeger (optional):
   - **Name**: `jaeger`
   - **Target**: `<your-tunnel-id>.cfargotunnel.com`
   - **Proxy status**: ✅ Proxied

3. Add wildcard CNAME for Knative services:
   - **Name**: `*`
   - **Target**: `<your-tunnel-id>.cfargotunnel.com`
   - **Proxy status**: ✅ Proxied

#### Step 6: Enable Cloudflare Tunnel in Helm Chart

After creating the sealed secret, enable the tunnel in your cluster-serverless infrastructure:

```bash
# Edit infra/values.yaml in cluster-serverless repo
cloudflareTunnel:
  enabled: true  # Change from false to true
```

Commit and push the change. ArgoCD will automatically deploy the tunnel pods.

#### Step 7: Verify Tunnel Deployment

```bash
# Check tunnel pods are running
kubectl get pods -n cloudflare-tunnel

# Check tunnel logs
kubectl logs -n cloudflare-tunnel -l app.kubernetes.io/name=cloudflare-tunnel

# Test access from your browser
# Visit: https://argocd.your-domain.com
```

**Expected result**: You should see the ArgoCD login page! 🎉

#### Why Deploy Tunnel in Kubernetes vs System Service?

**✅ Kubernetes Deployment (Recommended)**:
- Works across all scenarios (VPS, Hybrid, Homelab)
- Uses cluster DNS (e.g., `argocd-server.argocd.svc.cluster.local`)
- High availability (multiple replicas)
- Survives node restarts
- GitOps managed

**❌ System Service (Not Recommended)**:
- Only works on single node
- Can't use cluster DNS names
- Requires NodePort or port-forwarding
- Manual configuration on each node
- Not GitOps managed

## 📖 Configuration

### K0s Configuration

Edit `config/k0s.yaml` to customize your k0s cluster:
- Network settings (podCIDR, serviceCIDR)
- API server configuration
- Storage backend
- Extensions and Helm charts

### ArgoCD Configuration

The `manifests/argocd/cluster-bootstrap-app.yaml` defines the GitOps application that manages your cluster. Customize:
- Repository URL
- Target revision (branch/tag)
- Sync policy

## 🔧 Common Tasks

### View Cluster Status

```bash
sudo k0s status
kubectl get nodes
```

### Get Worker Join Token

```bash
sudo k0s token create --role=worker
```

### Reset k0s Installation

```bash
sudo k0s stop
sudo k0s reset
```

### Update ArgoCD Applications

ArgoCD automatically syncs from Git. To manually sync:

```bash
argocd app sync cluster-bootstrap
```

## 🛠️ Troubleshooting

### k0s controller won't start

- Check logs: `sudo journalctl -u k0scontroller -f`
- Verify port 6443 is available
- Ensure sufficient resources

### ArgoCD can't access repository

- Verify repository URL in `cluster-bootstrap-app.yaml`
- Check if repository is public or configure credentials
- Review ArgoCD logs: `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server`

### Sealed Secrets controller not working

- Verify controller is running: `kubectl get pods -n sealed-secrets`
- Check controller logs: `kubectl logs -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets-controller`

## 📚 Additional Resources

- [k0s Documentation](https://docs.k0sproject.io/)
- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Sealed Secrets Documentation](https://github.com/bitnami-labs/sealed-secrets)

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📝 License

This project is licensed under the terms specified in the LICENSE file.

## ⚠️ Security Notes

- Never commit unsealed secrets to Git
- Regularly rotate your sealed secrets encryption keys
- Use RBAC to control access to sealed secrets
- Keep your k0s and ArgoCD versions up to date