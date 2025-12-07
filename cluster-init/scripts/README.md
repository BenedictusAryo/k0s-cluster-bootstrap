
# cluster-init Scripts

This directory contains all scripts required for initial cluster bootstrap, secret generation, and GitOps workflows.

## Scripts
- `install-prerequisites.sh`: Installs required tools (Helm, kubeseal, etc.)
- `install-k0s-controller.sh`: Installs and configures the k0s controller node
- `install-k0s-worker.sh`: Installs and joins a k0s worker node
- `generate-tls-secret.sh`: Interactive script to generate and seal TLS secrets
- `generate-cloudflare-secret.sh`: Interactive script to generate and seal Cloudflare Tunnel secrets
- `cluster-entrypoint.sh`: Main entrypoint for secret generation, git diff/commit/push, and ArgoCD sync

## Usage

1. Run `cluster-entrypoint.sh` after installing the cluster to generate secrets and trigger the initial GitOps flow.
2. After bootstrap, ArgoCD will manage the cluster using the Helm chart at the root of the repository.
3. The root Helm chart will deploy the **infra-apps** subchart, which creates individual ArgoCD Applications for each infrastructure component (Cilium, cert-manager, Sealed Secrets, etc.).

## Troubleshooting

After running the scripts:
- Verify that the Cloudflare tunnel pods are running and not using hostNetwork: `kubectl get pods -n cloudflare-tunnel -o yaml | grep -i hostNetwork`
- Check that gateway services are accessible: `kubectl get svc -n gateway-system`
- Review tunnel logs for connectivity issues: `kubectl logs -n cloudflare-tunnel -l app.kubernetes.io/name=cloudflare-tunnel`
