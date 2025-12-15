# How to Configure MetalLB for External Access

This guide shows you how to configure MetalLB to expose services externally on your k0s cluster using public IP addresses.

---

## Overview of MetalLB in This Setup

MetalLB provides a network load-balancer implementation for Kubernetes clusters that don't run on a cloud provider. In this k0s cluster setup, MetalLB assigns IP addresses from a configured pool to Services of type LoadBalancer and Route traffic to those IPs to your Kubernetes services.

**How it works:**

1. **MetalLB Speaker**: A speaker pod runs on each node, advertising IP addresses from the configured pool using standard Layer 2 networking protocols (ARP for IPv4, NDP for IPv6) or BGP.
2. **IPAddressPool**: You define a range of IP addresses (the pool) that MetalLB can use for LoadBalancer services.
3. **L2Advertisement**: This resource tells MetalLB to advertise the IPs from a specific `IPAddressPool` using Layer 2 mode.
4. **Service Type LoadBalancer**: When you create a Kubernetes Service of type `LoadBalancer`, MetalLB will assign an IP address from its pool to that service.
5. **Direct Access**: Traffic to the LoadBalancer IP will be routed directly to your cluster nodes.

✅ **All service routing is managed declaratively via GitOps**
✅ **No external tunnel services required**
✅ **Direct IP access for better performance and flexibility**
✅ **Works with any service: ArgoCD, Grafana, your applications**

---

## Part 1: Plan Your IP Address Range

### Step 1: Determine Available IP Range

Before configuring MetalLB, you need to identify a range of IP addresses that:
- Are accessible from the internet (public IPs if your cluster is on a VPS, or local network IPs if on a homelab)
- Are not in use by other devices on your network
- Are in the same subnet as your cluster nodes

**For VPS deployments:**
- Obtain additional public IP addresses from your VPS provider (e.g., DigitalOcean, Linode, AWS)
- Or use the assigned public IP addresses of your VPS

**For homelab deployments:**
- Use an unused IP range in your local network subnet (e.g. 192.168.1.240-192.168.1.250)

### Step 2: Configure DNS Records

For each service you want to expose, create DNS A records pointing to IP addresses from your MetalLB pool:

**Example DNS Records:**
- `argocd.benedict-aryo.com` → `203.0.113.10` (IP from MetalLB pool)
- `grafana.benedict-aryo.com` → `203.0.113.11` (IP from MetalLB pool)
- `prometheus.benedict-aryo.com` → `203.0.113.12` (IP from MetalLB pool)

**DNS Provider Configuration:**
- Access your DNS provider (Cloudflare, GoDaddy, etc.)
- Create individual A records for each service
- Use IP addresses from your planned MetalLB address pool

---

## Part 2: Configure MetalLB in Your Cluster

### Step 1: Run the Cluster Bootstrap Script

The MetalLB configuration is handled by the cluster-entrypoint.sh script:

```bash
cd k0s-cluster-bootstrap/cluster-init/scripts

# Run the bootstrap script (if not already done)
./cluster-entrypoint.sh
```

During execution, the script will prompt:
```
Enter the IP address range for MetalLB (e.g., 192.168.1.200-192.168.1.250): 
```

Enter your IP address range (the one you planned in Step 1), for example:
```
203.0.113.10-203.0.113.20
```

### Step 2: Verify MetalLB Installation

```bash
# Check that MetalLB pods are running
kubectl get pods -n metallb-system

# Check that the IP address pool was created
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system

# Expected output should show your configured IP pool
```

### Step 3: Create LoadBalancer Services

Once MetalLB is configured, any Kubernetes Service of type LoadBalancer will automatically receive an IP from your pool.

**Example: ArgoCD LoadBalancer Service**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-lb
  namespace: argocd
spec:
  type: LoadBalancer
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
  - name: https
    port: 443
    targetPort: 8080
    protocol: TCP
  selector:
    app.kubernetes.io/name: argocd-server
```

When you apply this service, MetalLB will assign an IP address from your configured pool.

---

## Part 3: Configure Ingress with HTTPRoutes (Recommended)

In this setup, we combine MetalLB with Cilium's Gateway API implementation for more sophisticated routing.

### Configure Gateway and HTTPRoute Resources

**Example: Gateway for MetalLB LoadBalancer Service**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external-gateway
  namespace: gateway-system
spec:
  gatewayClassName: cilium
  listeners:
  - name: http
    protocol: HTTP
    port: 80
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: wildcard-tls-certificate  # Reference to your TLS secret
```

**Example: HTTPRoute for ArgoCD (direct infrastructure access)**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-route
  namespace: argocd
spec:
  parentRefs:
  - name: external-gateway
    namespace: gateway-system
  hostnames:
  - argocd.benedict-aryo.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: "/"
    backendRefs:
    - name: argocd-server
      namespace: argocd
      port: 80
```

This pattern allows you to:
- Use MetalLB to expose the Gateway service externally
- Use HTTPRoutes to route different hostnames to different services
- Maintain full GitOps control over routing configuration

---

## Part 4: Update Your Git Configuration

### Step 1: Create TLS Certificates (if using HTTPS)

For HTTPS services, create TLS certificates using cert-manager (already configured in this setup):

```bash
# Example certificate for your domain
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-tls-certificate
  namespace: gateway-system
spec:
  secretName: wildcard-tls-certificate
  issuerRef:
    name: letsencrypt-prod  # or letsencrypt-staging
    kind: ClusterIssuer
  commonName: '*.benedict-aryo.com'
  dnsNames:
  - '*.benedict-aryo.com'
  - 'benedict-aryo.com'
```

### Step 2: Apply Your Service and Route Configurations

Add your LoadBalancer services and HTTPRoutes to your Git repository under the templates directory:

```bash
git add templates/metallb/
git add templates/cluster-network/
git commit -m "Add MetalLB LoadBalancer services and HTTPRoutes"
git push origin main
```

### Step 3: Verify Configuration

```bash
# Check that LoadBalancer services received IPs from MetalLB pool
kubectl get svc -n argocd -l app.kubernetes.io/name=argocd-server

# Check Gateway and HTTPRoute status
kubectl get gateway -A
kubectl get httproute -A

# Verify external IP assignment
kubectl get svc -n gateway-system
```

---

## Summary: What Goes Where

| Component | Where | Purpose |
|-----------|-------|---------|
| **IP Address Pool** | `templates/metallb/ip-address-pool.yaml` | Defines IP range for LoadBalancer services |
| **LoadBalancer Services** | Kubernetes manifests in Git | Services exposed via MetalLB assigned IPs |
| **HTTPRoutes** | Git with Gateway API manifests | Defines hostname → service mappings |
| **DNS Records** | DNS Provider (Cloudflare, etc.) | Points subdomains to MetalLB-assigned IPs |

---

## Adding New Exposed Services

To expose new services via MetalLB:

1. **Deploy your service** as a Kubernetes Service (typically ClusterIP)
2. **Create a LoadBalancer service** that selects your application (or modify existing to LoadBalancer type)
3. **Create an HTTPRoute** that routes from your desired hostname to the service
4. **Update DNS records** to point the hostname to one of the MetalLB pool IPs
5. **Commit to Git** - ArgoCD will sync the configuration automatically

**Example adding Grafana:**
```bash
git add k0s-cluster-bootstrap/templates/cluster-network/grafana-httproute.yaml
git commit -m "Add Grafana route via MetalLB and HTTPRoute"
git push
```

No manual external configuration needed - everything is GitOps managed! 🎉

---

## Troubleshooting

### "LoadBalancer service stuck in <pending> state"
- Check MetalLB pods are running: `kubectl get pods -n metallb-system`
- Verify IP pool configuration: `kubectl get ipaddresspool -n metallb-system`
- Ensure your IP range is accessible and not in use

### "IP address not assigned from pool"
- Check L2Advertisement exists: `kubectl get l2advertisement -n metallb-system`
- Verify MetalLB controller logs: `kubectl logs -n metallb-system -l app.kubernetes.io/component=controller`

### "Service not accessible externally"
- Check that the assigned LoadBalancer IP is correctly configured in DNS
- Verify firewall rules allow traffic on the required ports
- Test directly: `curl -v http://<loadbalancer-ip>`

### "HTTPRoute not routing properly"
- Check Gateway status: `kubectl get gateway external-gateway -n gateway-system`
- Verify HTTPRoute binding: `kubectl get httproute -n argocd`
- Review Gateway logs: `kubectl logs -n gateway-system -l app.kubernetes.io/name=cilium`