
# cluster-init Scripts

This directory contains all scripts required for initial cluster bootstrap, secret generation, and GitOps workflows.

## Scripts
- `install-prerequisites.sh`: Installs required tools (Helm, kubeseal, etc.)
- `install-k0s-controller.sh`: Installs and configures the k0s controller node
- `install-k0s-worker.sh`: Installs and joins a k0s worker node
- `generate-tls-secret.sh`: Interactive script to generate and seal TLS secrets
- `configure-metallb-pool.sh`: Interactive script to configure MetalLB IP address pool
- `cluster-entrypoint.sh`: Main entrypoint for infrastructure setup, MetalLB configuration, git diff/commit/push, and ArgoCD sync

## Usage

1. Run `cluster-entrypoint.sh` after installing the cluster to generate secrets and trigger the initial GitOps flow.
2. After bootstrap, ArgoCD will manage the cluster using the Helm chart at the root of the repository.
3. The root Helm chart will deploy the **infra-apps** subchart, which creates individual ArgoCD Applications for each infrastructure component (Cilium, cert-manager, Sealed Secrets, etc.).

## Troubleshooting

After running the scripts:
- Verify that MetalLB pods are running: `kubectl get pods -n metallb-system`
- Check that gateway services are accessible: `kubectl get svc -n gateway-system`
- Verify MetalLB IP pool configuration: `kubectl get ipaddresspool -n metallb-system`
- Review MetalLB controller logs: `kubectl logs -n metallb-system -l app.kubernetes.io/component=controller`
