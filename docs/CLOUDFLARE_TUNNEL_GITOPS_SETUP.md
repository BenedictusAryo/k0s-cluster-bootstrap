# How to Enable GitOps Routing for Cloudflare Tunnel

This guide shows you **exactly** what to do in Cloudflare UI and what to update in your Git repo.

---

## Part 1: Get Information from Cloudflare Dashboard

### Step 1: Access Cloudflare Zero Trust Dashboard

1. Go to: **https://one.dash.cloudflare.com/**
2. Select your account
3. Navigate to: **Networks** → **Tunnels**

### Step 2: Find or Create Your Tunnel

**If you already have a tunnel:**
- Click on your existing tunnel name
- Skip to Step 3

**If you need to create a new tunnel:**

1. Click **"Create a tunnel"**
2. Choose **"Cloudflared"** as connector type
3. Click **"Next"**
4. Enter tunnel name (e.g., `k0s-linode-tunnel`)
5. Click **"Save tunnel"**

6. **Install connectors page** - You'll see installation instructions
   - **SKIP the installation** (we're running cloudflared in Kubernetes, not on a local machine)
   - Click **"Next"** to continue

7. **Route tunnel page** - You'll see a form with 3 fields:
   
   **⚠️ IMPORTANT: Fill in a temporary route (we'll delete it later for GitOps)**
   
   Fill the form like this:
   
   - **Subdomain**: `temp` (or any placeholder)
   - **Domain**: Select your domain (e.g., `benedict-aryo.com`)
   - **Type**: Select `HTTP`
   - **URL**: `http://localhost:8000` (placeholder - doesn't matter)
   
   Click **"Save tunnel"**
   
   **Why?** Cloudflare requires at least one route to create a tunnel. We'll delete this route later when we enable GitOps mode.

8. After saving, you'll see your tunnel dashboard
   - Continue to Step 3 below to get the Tunnel ID

### Step 3: Get Tunnel ID

On your tunnel's overview page, look for the **Tunnel ID**:

**Method 1 - From URL:**
```
https://one.dash.cloudflare.com/[account-id]/networks/tunnels/[TUNNEL-ID]
                                                             ^^^^^^^^
                                                        This is your Tunnel ID
```

**Method 2 - From the page:**
- Look for "Tunnel ID" field on the overview page
- It looks like: `1632a9c2-9732-4e47-8754-17c9b0a23c68`

📝 **Copy this Tunnel ID** - you'll need it for the config!

### Step 4: Get credentials.json for GitOps Mode

⚠️ **IMPORTANT**: Cloudflare's web UI creates **token-based** tunnels, which DON'T have credentials.json files.

To get credentials.json for GitOps config-based mode, you need to create the tunnel using the CLI instead.

**Method 1: Create Tunnel Using cloudflared CLI (For Full GitOps)**

Run these commands on your local machine:

```bash
# Install cloudflared on your Mac
brew install cloudflared

# Login to Cloudflare
cloudflared tunnel login
# This opens a browser - select your domain

# Create a new tunnel
cloudflared tunnel create k0s-linode-tunnel

# This creates credentials.json automatically!
# Location: ~/.cloudflared/<TUNNEL-ID>.json

# Get your tunnel ID
cloudflared tunnel list
# Copy the UUID shown

# Find the credentials file
ls -la ~/.cloudflared/
# You'll see: <tunnel-id>.json ← This is your credentials.json!

# Copy it to your working directory
cp ~/.cloudflared/<tunnel-id>.json ~/credentials.json
```

Now you have:
- ✅ Tunnel ID (from `cloudflared tunnel list`)
- ✅ credentials.json file (at `~/credentials.json`)

Continue to **Part 2** below to enable GitOps routing.

**Method 2: Simplified GitOps with Token Mode + Cilium Gateway (RECOMMENDED)**

You still don't need `credentials.json`. We keep token mode, but the wildcard route now terminates on the Gateway API listener so that HTTPRoutes (in Git) decide where requests land.

**The Simple Approach:**

In Cloudflare Dashboard, create just **ONE route**:
- **Subdomain**: `*` (wildcard)
- **Domain**: `benedict-aryo.com`
- **Type**: `HTTPS`
- **URL**: `https://cloudflare-gateway.gateway-system.svc.cluster.local:443`
- **TLS Options**: Enable "No TLS Verify" (gateway serves an internal cert)

That's it! One route in the dashboard.

**Then everything else is managed via Gateway HTTPRoutes + Knative manifests in Git:**

```yaml
# Example: Gateway HTTPRoute for ArgoCD (direct infrastructure access)
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

Knative Services keep working the same way—they expose hostnames such as `my-app.default.benedict-aryo.com`. We add a pass-through HTTPRoute (once) that forwards those wildcard hostnames to the `istio-ingressgateway` Service, and Istio+Knative continue doing revision-level routing:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: knative-wildcard
  namespace: gateway-system
spec:
  parentRefs:
  - name: cloudflare-gateway
  hostnames:
  - "*.benedict-aryo.com"
  rules:
  - backendRefs:
    - name: istio-ingressgateway
      namespace: istio-system
      port: 80
```

**How it works:**

1. **Cloudflare Tunnel**: Receives all `*.benedict-aryo.com` traffic, sends it to the Cilium `cloudflare-gateway`
2. **Gateway API**: Evaluates HTTPRoutes from Git—either routes directly to the service (infra apps) or forwards to Kourier for Knative hostnames
3. **Kourier + Knative**: Handle per-revision traffic splitting for serverless workloads

✅ **All routing logic in Git (GitOps)**
✅ **Only ONE static route in dashboard (never changes)**
✅ **No manual route updates needed**
✅ **Works with any service: ArgoCD, Jaeger, your apps**

This is actually the **best practice** approach!

---

**Which mode should you choose?**

| Feature | Token + Dashboard Routes | Token + Gateway HTTPRoutes (Recommended) | Config + GitOps Routes |
|---------|-------------------------|-------------------------------------------|------------------------|
| Setup complexity | ✅ Simple | ✅ Simple | ⚠️ Complex |
| Infrastructure routes | Dashboard | ✅ Git (Gateway HTTPRoutes) | ✅ Git |
| Knative routes | Dashboard | ✅ Git (pass-through to Istio) | ✅ Git |
| Need CLI? | ❌ No | ❌ No | ✅ Yes |
| Need credentials.json? | ❌ No | ❌ No | ✅ Yes |
| Cloudflare dashboard changes? | Frequent | One-time wildcard | None (managed via config file) |
| Best fit | Quick tests | Ongoing GitOps clusters | Full Cloudflare-managed tunnel config |

**Recommendation for your use case:**

Use **Token + Gateway HTTPRoutes** (Method 2):
1. Keep token-based tunnel (simpler) but point the wildcard route to `cloudflare-gateway`
2. Manage every hostname—infra + Knative—via HTTPRoutes stored in Git
3. Knative keeps creating URLs like `my-app.default.benedict-aryo.com`; the Gateway pass-through sends them to Kourier automatically
4. ✅ Full GitOps control of ingress without touching Cloudflare after day one

You get 90% of the config-based benefits while staying in the simple token mode.

---

## Part 2: Update Your Git Configuration

### Step 1: Create Sealed Secret with credentials.json

```bash
# Navigate to cluster-serverless repo
cd cluster-serverless

# Create sealed secret with credentials file
kubectl create secret generic cloudflare-tunnel-secret \
  --namespace=cloudflare-tunnel \
  --from-file=credentials.json=/path/to/your/credentials.json \
  --dry-run=client -o yaml | \
kubeseal --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --format=yaml > /tmp/sealed-secret-temp.yaml

# This script will:
# 1. Create the cloudflare tunnel secret using your tunnel token
# 2. Seal it using kubeseal
# 3. Place it in cluster-init/templates/cloudflare-tunnel/secret.yaml
```

### Step 2: Enable Cloudflare Tunnel in Configuration

In the k0s-cluster-bootstrap repository, edit `cluster-init/values.yaml` and update the Cloudflare Tunnel section:

```yaml
cloudflareTunnel:
  enabled: true
  namespace: cloudflare-tunnel
  
  # Change this to enable GitOps routing
  useConfigFile: true  # ← Change from false to true
  
  # Add your Tunnel ID here
  tunnelId: "1632a9c2-9732-4e47-8754-17c9b0a23c68"  # ← Paste your Tunnel ID
  
  replicas: 2
  
  credentials:
    useExistingSecret: false
    secretName: cloudflare-tunnel-secret
  
  # These routes are now GitOps managed!
  ingress:
    - hostname: "*.benedict-aryo.com"
      service: https://cloudflare-gateway.gateway-system.svc.cluster.local:443
      originRequest:
        noTLSVerify: true
```

### Step 3: Commit and Push

**Note**: Configuration is in the `k0s-cluster-bootstrap` repository, not cluster-serverless.

```bash
# Review changes
git diff

# Add files
git add cluster-init/values.yaml

# Commit
git commit -m "Enable GitOps config-based Cloudflare Tunnel routing"

# Push
git push origin main
```

### Step 4: Wait for ArgoCD to Sync

```bash
# ArgoCD syncs automatically within 3 minutes
# Or force sync immediately:
kubectl get app cluster-init -n argocd

# Watch the sync
kubectl get pods -n cloudflare -w
```

### Step 5: Verify

```bash
# Check that new config is loaded
kubectl get configmap cloudflare-tunnel-config -n cloudflare -o yaml

# Check pods restarted with new config
kubectl get pods -n cloudflare

# Check logs
kubectl logs -n cloudflare -l app.kubernetes.io/name=cloudflared

# Should see:
# "Registered tunnel connection"
# "Configuration loaded from: /etc/cloudflared/config/config.yaml"
```

---

## Part 3: Remove Manual Routes from Dashboard (IMPORTANT!)

After enabling GitOps mode, you MUST remove the manually configured routes from Cloudflare dashboard:

1. Go to: **https://one.dash.cloudflare.com/**
2. Navigate to: **Networks** → **Tunnels**
3. Click your tunnel name
4. Go to **"Public Hostname"** tab
5. **Delete all manually configured routes** (click X on each)
6. Leave it **empty** - routes now come from Git!

**Why?**
- GitOps mode uses HTTPRoutes defined in Git
- Manual dashboard routes will conflict
- Git becomes the single source of truth

---

## Summary: What Goes Where

| What | Where | Why |
|------|-------|-----|
| **Tunnel ID** | `values.yaml` → `tunnelId` | Identifies your tunnel |
| **credentials.json** | Sealed Secret → `secret.yaml` | Authenticates with Cloudflare |
| **Routes** | `values.yaml` → `ingress` array | Defines hostname → service mappings |
| **Dashboard** | Empty (no routes configured) | Git is source of truth |

---

## Adding New Routes (After Migration)

With GitOps enabled, add routes by creating HTTPRoute resources in the k0s-cluster-bootstrap repository:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana-route
  namespace: monitoring
spec:
  parentRefs:
  - name: cloudflare-gateway
    namespace: gateway-system
  hostnames:
  - grafana.benedict-aryo.com
  rules:
  - backendRefs:
    - name: grafana
      namespace: monitoring
      port: 80
```

Then:
```bash
git add k0s-cluster-bootstrap/templates/cluster-network/grafana-httproute.yaml  # or appropriate path
git commit -m "Add Grafana route to Cloudflare Tunnel via HTTPRoute"
git push
```

ArgoCD syncs automatically - no dashboard needed! 🎉

---

## Troubleshooting

### "Failed to read tunnel credentials"
- Check secret has `credentials.json` key:
  ```bash
  kubectl get secret cloudflare-tunnel-secret -n cloudflare -o jsonpath='{.data.credentials\.json}' | base64 -d | jq
  ```

### "Tunnel ID mismatch"
- Make sure `tunnelId` in values.yaml matches the ID in credentials.json

### "Configuration invalid"
- Check configmap was created:
  ```bash
  kubectl get configmap cloudflare-tunnel-config -n cloudflare -o yaml
  ```

### Routes not working
- Verify dashboard has NO manual routes
- Check tunnel status: should show "Healthy" with 2 connectors
- Test: `curl -v https://argocd.benedict-aryo.com`

- Check tunnel status: should show "Healthy" with 2 connectors
- Test: `curl -v https://argocd.benedict-aryo.com`
