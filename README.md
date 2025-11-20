
# k0s-cluster-bootstrap (Helm Modular)

Helm-based, GitOps-powered Kubernetes cluster bootstrap for **VPS/Homelab** deployments using [k0s](https://k0sproject.io/), [ArgoCD](https://argo-cd.readthedocs.io/), [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets), [Cilium](https://cilium.io/), and [Cloudflare Gateway](https://www.cloudflare.com/).

> 🏡 **Serverless Platform for VPS/Homelab with Full GitOps**
> 

> This setup provides:
> - **Single Helm chart (`cluster-init`)**: Manages all cluster-wide infrastructure (Cilium, Sealed Secrets, ArgoCD, Cloudflare Gateway, etc.)
> - **App-of-Apps Pattern**: ArgoCD Application CRs (templated) reference the cluster-serverless Helm chart for serverless workloads
> - **Interactive secret generation**: Scripts for TLS and Cloudflare Tunnel secrets, with git diff/commit/push before ArgoCD sync
> - **Self-healing GitOps**: All infra is declarative, version-controlled, and auto-reconciled
> - **Works behind CGNAT, VPS, or hybrid deployments**

## 💡 Why This Setup?

**Traditional Kubernetes challenges**:
- ❌ Requires static public IP
- ❌ Complex port forwarding setup
- ❌ Manual SSL certificate management
- ❌ Doesn't work behind CGNAT
- ❌ Heavy resource requirements
- ❌ Manual infrastructure management

**Our solution**:
- ✅ **Serverless Platform**: Knative for scale-to-zero workloads
- ✅ **App-of-Apps GitOps**: cluster-init manages all infrastructure
- ✅ **Self-Healing**: Delete any app, it auto-recreates via GitOps
- ✅ Works behind CGNAT with Cloudflare Tunnel
- ✅ Lightweight k0s (50-70% less resources than full K8s)


## 📊 Project Structure

```
k0s-cluster-bootstrap/
├── Chart.yaml                  # Main Helm chart for all cluster-wide infrastructure
├── values.yaml                 # Helm values for infrastructure
├── templates/                  # Helm templates (Cilium, Sealed Secrets, ArgoCD, Cloudflare Gateway, etc.)
├── cluster-init/
│   └── scripts/
│       ├── cluster-entrypoint.sh
│       ├── install-prerequisites.sh
│       ├── install-k0s-controller.sh
│       ├── install-k0s-worker.sh
│       ├── generate-tls-secret.sh
│       └── generate-cloudflare-secret.sh
├── manifests/
│   └── applications/
│       └── cluster-init-app.yaml
├── config/
│   └── k0s.yaml
└── README.md
```

- The **root Helm chart** manages all cluster-wide infrastructure.
- The `cluster-init/scripts/` directory contains one-time bootstrap scripts (run before GitOps takes over).
- After running `cluster-init/scripts/cluster-entrypoint.sh`, ArgoCD will sync the root Helm chart (`k0s-cluster-bootstrap`), not a subdirectory.
cluster-serverless/ (separate repo)
├── Chart.yaml                         # Root Helm chart with subchart dependencies
├── values.yaml                        # Global config + subchart enables
├── charts/                            # Subcharts
│   ├── serverless-infra/              # Serverless infrastructure subchart
│   │   ├── Chart.yaml
│   │   ├── values.yaml                # Knative, Kourier, Jaeger, OpenTelemetry config
│   │   └── templates/                 # Infrastructure components + Jaeger HTTPRoute
│   └── serverless-app/                # Serverless applications subchart
│       ├── Chart.yaml
│       ├── values.yaml                # App configurations
│       └── templates/                 # Example hello-world Knative Service
└── README.md
```


## 🔄 GitOps Flow (Helm Modular, App-of-Apps)

1. **Bootstrap phase**
   - Install k0s controller and prerequisites
   - Run `cluster-init/scripts/cluster-entrypoint.sh` (installs Cilium, Sealed Secrets, ArgoCD, generates secrets, creates cluster-init ArgoCD Application)
   - cluster-init ArgoCD Application deploys the cluster-init Helm chart
   - cluster-init Helm chart creates templated ArgoCD Applications (controlled by `active` flags)

2. **Selective deployment phase**
   - cluster-init creates `cluster-serverless` ArgoCD Application (when `active: true` in values.yaml)
   - ArgoCD syncs cluster-serverless Helm chart (app-of-apps)
   - cluster-serverless deploys serverless-infra subchart (Knative, Kourier, Jaeger, OpenTelemetry)
   - cluster-serverless deploys serverless-app subchart (example applications)

3. **Self-healing**
   - Delete any infra or app → ArgoCD/Helm will auto-recreate from Git
   - To enable/disable components: edit `active` flags in `cluster-init/values.yaml` → sync cluster-init ArgoCD app

## 🚀 Quick Start


### 📦 Installation Steps (Helm Modular)

#### Step 1: Install Prerequisites & K0s Controller

On the **controller node** (VPS recommended):

```bash
git clone https://github.com/BenedictusAryo/k0s-cluster-bootstrap.git
cd k0s-cluster-bootstrap/cluster-init/scripts

# Install prerequisites (Helm, kubeseal)
chmod +x *.sh
./install-prerequisites.sh

# Install K0s controller
./install-k0s-controller.sh
# Choose option 1 for single-node cluster (controller runs workloads)
```

The script will:
- Install k0s binary
- Configure controller using `config/k0s.yaml`
- Start k0s service
- Remove control-plane taint (allows pod scheduling)
- Generate kubeconfig at `~/.kube/config`

#### Step 2: Bootstrap Infrastructure & ArgoCD

Run the interactive bootstrap script:

```bash
./cluster-entrypoint.sh
```

This script will:
1. Install **Gateway API CRDs** (required for Cilium Gateway)
2. Install **Cilium CNI** (eBPF-based networking) with Gateway API controller
3. Install **Sealed Secrets controller** (encrypted secrets in Git)
4. Install **ArgoCD** (GitOps engine)
5. Generate **TLS certificates** and **Cloudflare Tunnel secrets**
6. Show **git diff** for review, prompt to **commit/push**
7. Create the **`cluster-init` ArgoCD Application** (manages all infrastructure)

The cluster-init ArgoCD Application will deploy:
- ✅ **Cilium Gateway** + HTTPRoutes (Cloudflare routing)
- ✅ **Cloudflare Tunnel** (secure outbound access)
- ✅ **ArgoCD UI** (GitOps management)
- ❌ **cluster-serverless** (disabled by default via `active: false`)

#### Step 3: Enable Serverless Components (Optional)

To enable the full serverless platform:

```bash
# Edit cluster-init values
vim ../values.yaml

# Change in applications section:
# active: false → active: true

# Commit and push
git add values.yaml
git commit -m "Enable cluster-serverless deployment"
git push origin main

# Sync cluster-init ArgoCD Application
# ArgoCD UI: https://argocd.benedict-aryo.com
# Find "cluster-init" → Sync
```

This enables:
- ✅ **Knative Serving** (scale-to-zero HTTP services)
- ✅ **Knative Eventing** (event-driven architecture)
- ✅ **Kourier** (lightweight ingress)
- ✅ **Jaeger** (distributed tracing)
- ✅ **OpenTelemetry** (observability)
- ✅ **Example hello-world app**

#### Step 4: Configure Cloudflare (Already Done in Bootstrap)

The bootstrap script already generated Cloudflare Tunnel secrets and configured the infrastructure. The single wildcard route sends all `*.benedict-aryo.com` traffic to the Cilium Gateway, which routes to:

- **ArgoCD UI**: `https://argocd.benedict-aryo.com`
- **Jaeger UI**: `https://jaeger.benedict-aryo.com` (when serverless enabled)
- **Knative apps**: `https://<app-name>.benedict-aryo.com` (when serverless enabled)

**Verify routing works:**
```bash
# Check Cilium Gateway
kubectl get gateway -A

# Test ArgoCD access
curl -k https://argocd.benedict-aryo.com
```

All application routing is managed via Kubernetes manifests in Git:

**For infrastructure services** (ArgoCD, Jaeger, etc.):
```yaml
# Example: ArgoCD Gateway HTTPRoute
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
   name: argocd-route
   namespace: argocd
spec:
   parentRefs:
   - name: cloudflare-gateway
      namespace: gateway-system
   hostnames:
   - argocd.benedict-aryo.com
   rules:
   - backendRefs:
      - name: argocd-server
         namespace: argocd
         port: 443
```

**For serverless applications**:
```yaml
# Knative Service - automatically creates route
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: my-app
  namespace: default
spec:
  template:
    spec:
      containers:
      - image: gcr.io/knative-samples/helloworld-go
```
Automatically accessible at: `my-app.default.benedict-aryo.com`

**How it works**:
1. User accesses `argocd.benedict-aryo.com`
2. Cloudflare routes to the `cloudflare-gateway` (via wildcard route)
3. Gateway matches the HTTPRoute and forwards directly to `argocd-server`
4. For Knative hostnames, the wildcard HTTPRoute forwards to `kourier-gateway`, which performs revision-level routing
5. **All routing logic in Git!** 🎉

#### Step 4: Verify Deployment

```bash
# Check ArgoCD applications
kubectl get app -n argocd

# Expected output:
# NAME                       SYNC STATUS   HEALTH STATUS
# cilium                     Synced        Healthy
# cluster-init               Synced        Healthy
# cluster-serverless-infra   Synced        Healthy
# sealed-secrets             Synced        Healthy


#### Step 2: Deploy cluster-init Helm Chart & Run Entrypoint

```bash
# From the root of the repo
cd cluster-init
helm install cluster-init .

# Run the entrypoint script for secret generation and GitOps flow
cd scripts
./cluster-entrypoint.sh
# This will:
# - Prompt for secret values (TLS, Cloudflare Tunnel, etc.)
# - Show a git diff and prompt for confirmation
# - Commit and push changes to main
# - Trigger ArgoCD sync
```

#### Step 3: Configure Cloudflare Tunnel (One-Time)

In Cloudflare Zero Trust Dashboard, create just **ONE wildcard route**:
- **Subdomain**: `*` (wildcard)
- **Domain**: your domain (e.g., `benedict-aryo.com`)
- **Type**: `HTTPS`
- **URL**: `https://cloudflare-gateway.gateway-system.svc.cluster.local:443`
- **TLS Options**: Enable "No TLS Verify"

**All further routing is managed in Git via HTTPRoutes and ArgoCD Applications.**
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

#### Troubleshooting Common Tunnel Issues

If you encounter 502 Bad Gateway errors:
1. Check tunnel logs: `kubectl logs -n cloudflare-tunnel -l app.kubernetes.io/name=cloudflare-tunnel`
2. Look for "connection refused" or "no such host" errors
3. Verify that the service name in Cloudflare tunnel configuration matches the actual Kubernetes service name (e.g., `cilium-gateway-cloudflare-gateway.gateway-system.svc.cluster.local`)

**Note**: The tunnel pods run without `hostNetwork` to enable access to internal cluster services.

#### Why Deploy Tunnel in Kubernetes vs System Service?

**✅ Kubernetes Deployment (Recommended)**:
- Works across all scenarios (VPS, Hybrid, Homelab)
- Uses cluster DNS (e.g., `argocd-server.argocd.svc.cluster.local`)
- High availability (multiple replicas)
- Survives node restarts
- GitOps managed
- Proper service networking for internal connections

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
# Trigger sync using kubectl (no CLI needed)
kubectl patch application cluster-init -n argocd --type merge -p '{
  "metadata": {
    "annotations": {
      "argocd.argoproj.io/sync": "true"
    }
  }
}'

# Check sync status
kubectl get application cluster-init -n argocd
```

Or use the ArgoCD UI at `https://argocd.benedict-aryo.com`

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