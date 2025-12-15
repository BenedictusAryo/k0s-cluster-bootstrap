# ⚡️ ArgoCD Installation & HTTPRoute Management

**ArgoCD is not installed by this chart.**
You must install ArgoCD using the official Helm chart (or as an app-of-apps child) before deploying this chart. Example:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd \
   --namespace argocd --create-namespace \
   --set server.extraArgs={--insecure}
```

**Namespace Management:**
- The `argocd` namespace is created by this chart with the annotation `helm.sh/resource-policy: keep`.
- This ensures Helm will not delete the namespace on uninstall, and avoids adoption conflicts if ArgoCD is already present.

**HTTPRoute Management:**
- The ArgoCD HTTPRoute is managed by this chart (see `templates/argocd-httproute.yaml`).
- The hostname and enablement are controlled via `values.yaml`:

```yaml
argocd:
   httproute:
      enabled: true
      hostname: argocd.benedict-aryo.com
```

**Best Practice:**
- Do not manage ArgoCD's own resources (ConfigMaps, Deployments, etc.) in this chart. Only manage the HTTPRoute and namespace if needed.
- Use the app-of-apps pattern: let ArgoCD manage itself, and use this chart for cluster-wide infra and routing.

---

# k0s-cluster-bootstrap (Helm Modular)

Helm-based, GitOps-powered Kubernetes cluster bootstrap for **VPS/Homelab** deployments using [k0s](https://k0sproject.io/), [ArgoCD](https://argo-cd.readthedocs.io/), [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets), [Cilium](https://cilium.io/), and [MetalLB](https://metallb.universe.tf/).

> 🏡 **Serverless Platform for VPS/Homelab with Full GitOps**
> 

> This setup provides:
> - **Single Helm chart (`cluster-init`)**: Manages all cluster-wide infrastructure (Cilium, Sealed Secrets, ArgoCD, MetalLB, etc.)
> - **App-of-Apps Pattern**: ArgoCD Application CRs (templated) reference the cluster-serverless Helm chart for serverless workloads
> - **Interactive secret generation**: Scripts for TLS secrets, with git diff/commit/push before ArgoCD sync
> - **Self-healing GitOps**: All infra is declarative, version-controlled, and auto-reconciled
> - **Exposes services with Public IP, works behind CGNAT, VPS, or hybrid deployments**

## 💡 Why This Setup?

**Traditional Kubernetes challenges**:
- ❌ Requires static public IP (can be solved with MetalLB)
- ❌ Complex port forwarding setup (simplified with MetalLB)
- ❌ Manual SSL certificate management
- ❌ Doesn't work behind CGNAT (can be solved with MetalLB and proper routing)
- ❌ Heavy resource requirements
- ❌ Manual infrastructure management

**Our solution**:
- ✅ **MetalLB** (exposes services with public IP)
- ✅ **Cilium Gateway + MetalLB** (simplified port forwarding)
- ✅ **cert-manager + Let's Encrypt** (automatic certificate management)
- ✅ **Works behind CGNAT** (via MetalLB and a reverse proxy on the host if needed)
- ✅ **k0s lightweight** (single binary, low resources)
- ✅ **GitOps with ArgoCD** (infrastructure as code)
- ✅ **Serverless Platform**: Knative for scale-to-zero workloads
- ✅ **App-of-Apps GitOps**: cluster-init manages all infrastructure
- ✅ **Self-Healing**: Delete any app, it auto-recreates via GitOps
- ✅ Exposes services with Public IP and works behind CGNAT with MetalLB
- ✅ Lightweight k0s (50-70% less resources than full K8s)


## 📊 Project Structure

```
k0s-cluster-bootstrap/
├── Chart.yaml                  # Main Helm chart for cluster-wide bootstrap
├── values.yaml                 # Helm values for infrastructure
├── charts/                     # Subcharts
│   └── infra-apps/             # Infrastructure applications as ArgoCD Applications
│       ├── Chart.yaml
│       ├── values.yaml         # List of infrastructure ArgoCD Applications
│       ├── templates/          # Application template that iterates over infraApps
│       │   └── application.yaml
│       └── helm-values/        # Individual values files for each infrastructure component
│           ├── cilium-values.yaml
│           ├── cert-manager-values.yaml
│           ├── argocd-values.yaml
│           └── ...
├── templates/                  # Helm templates for core cluster components
├── cluster-init/
│   └── scripts/
│       ├── cluster-entrypoint.sh
│       ├── install-prerequisites.sh
│       ├── install-k0s-controller.sh
│       ├── install-k0s-worker.sh

├── config/
│   └── k0s.yaml
└── README.md
```

- The **root Helm chart** bootstraps ArgoCD and manages the infra-apps subchart.
- The **infra-apps subchart** defines infrastructure components as ArgoCD Applications (app of apps pattern).
- The `cluster-init/scripts/` directory contains one-time bootstrap scripts (run before GitOps takes over).
- After running `cluster-init/scripts/cluster-entrypoint.sh`, ArgoCD will sync the root Helm chart (`k0s-cluster-bootstrap`) and deploy infrastructure via ArgoCD Applications.
cluster-serverless/ (separate repo)
├── Chart.yaml                         # Root Helm chart with subchart dependencies
├── values.yaml                        # Global config + subchart enables
├── charts/                            # Subcharts
│   ├── serverless-infra/              # Serverless infrastructure subchart
│   │   ├── Chart.yaml
│   │   ├── values.yaml                # Knative, Istio, Jaeger, OpenTelemetry config
│   │   └── templates/                 # Infrastructure components + Jaeger HTTPRoute
│   └── serverless-app/                # Serverless applications subchart
│       ├── Chart.yaml
│       ├── values.yaml                # App configurations
│       └── templates/                 # Example hello-world Knative Service
├── app/                               # Individual Knative applications (like aiplatform-dev)
│   ├── hello-knative/                 # Example Knative app
│   │   ├── values.yaml                # App-specific configuration
│   │   └── application.env            # Non-sensitive environment variables
│   └── echo-server/                   # Another example app
│       ├── values.yaml                # App-specific configuration
│       └── application.env            # Non-sensitive environment variables
├── templates/                         # Knative Service template for apps
│   └── knativeservice.yaml            # Template for Knative services
└── README.md
```

## 🔄 GitOps Flow (Helm Modular, App-of-Apps)

1. **Bootstrap phase**
   - Install k0s controller and prerequisites
   - Run `cluster-init/scripts/cluster-entrypoint.sh` (installs minimal components: Gateway API CRDs, ArgoCD; generates secrets; creates cluster-init ArgoCD Application)
   - cluster-init ArgoCD Application deploys the root Helm chart
   - Root Helm chart deploys **infra-apps** subchart
   - **infra-apps** creates individual ArgoCD Applications for each infrastructure component (Cilium, cert-manager, Sealed Secrets, etc.)

2. **Selective deployment phase**
   - cluster-init creates `cluster-serverless` ArgoCD Application (when `active: true` in values.yaml)
   - ArgoCD syncs cluster-serverless Helm chart (app-of-apps)
   - cluster-serverless deploys serverless-infra subchart (Knative, Istio, Jaeger, OpenTelemetry)
   - cluster-serverless deploys serverless-app subchart (example applications)

3. **Knative Applications Management**
   - Knative applications are managed in the cluster-serverless repository in the app/ directory (similar to aiplatform-dev)
   - Each Knative app has its own directory with values.yaml and application.env
   - Individual ArgoCD Applications can be created for each Knative app following the app generator pattern

4. **Environment Variables Management**
   - Non-sensitive environment variables are stored in `application.env` and `values.yaml` in the app directory
   - Sensitive data is managed through Kubernetes Secrets, preferably encrypted as SealedSecrets
   - Support for both ConfigMaps (non-sensitive) and Secrets (sensitive) environment configuration
   - Follows security best practices: no plain text secrets in Git repositories

5. **Self-healing**
   - Delete any infra or app → ArgoCD/Helm will auto-recreate from Git
   - To enable/disable components: edit `infraApps` list in `charts/infra-apps/values.yaml` → sync cluster-init ArgoCD app

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
2. Install **Cilium CLI** if not present
3. Install **ArgoCD** (GitOps engine - bootstrap only)
4. Generate **TLS certificates**
5. Show **git diff** for review, prompt to **commit/push**
6. Create the **`cluster-init` ArgoCD Application** (manages all infrastructure via infra-apps)

The cluster-init ArgoCD Application will deploy:
- ✅ **infra-apps chart** (deploys infrastructure as separate ArgoCD Applications)
- ✅ **Cilium** (CNI with Gateway API controller)
- ✅ **cert-manager** (automatic certificate management)
- ✅ **Sealed Secrets** (encrypted secrets)
- ✅ **Knative Operator** (serverless platform)
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
- ✅ **Istio Gateway** (integrated with Knative)
- ✅ **cert-manager** (automatic Let's Encrypt certificates)
- ✅ **Jaeger** (distributed tracing)
- ✅ **OpenTelemetry** (observability)
- ✅ **Example hello-world app**

#### Step 4: Configure MetalLB IP Address Pool

The `cluster-entrypoint.sh` script will prompt you for the IP address range to be used by MetalLB. This range should consist of IP addresses available on your network that MetalLB can allocate to LoadBalancer services.

**Example**: `192.168.1.240-192.168.1.250`

Ensure these IP addresses are not already in use and are within the same subnet as your cluster nodes.

#### How it works (MetalLB)

MetalLB operates in two modes: Layer 2 (ARP/NDP) and BGP. For most homelab/VPS setups, Layer 2 mode is sufficient and simpler to configure.

1. **MetalLB Speaker**: A speaker pod runs on each node, advertising IP addresses from the configured pool using standard Layer 2 networking protocols (ARP for IPv4, NDP for IPv6).
2. **IPAddressPool**: You define a range of IP addresses (the pool) that MetalLB can use.
3. **L2Advertisement**: This resource tells MetalLB to advertise the IPs from a specific `IPAddressPool` using Layer 2 mode.
4. **Service Type LoadBalancer**: When you create a Kubernetes Service of type `LoadBalancer`, MetalLB will assign an IP address from its pool to that service.
5. **Direct Access**: Traffic to the LoadBalancer IP will be routed directly to your cluster nodes.

All application routing is managed via Kubernetes manifests in Git:

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

### MetalLB not assigning IPs

- Verify MetalLB speaker and controller pods are running: `kubectl get pods -n metallb-system`
- Check MetalLB controller logs: `kubectl logs -n metallb-system -l app.kubernetes.io/component=controller`
- Check IPAddressPool and L2Advertisement configuration: `kubectl get ipaddresspool -n metallb-system` and `kubectl get l2advertisement -n metallb-system`
- Ensure your IP address range is valid and not in use by other devices.

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