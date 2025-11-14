# k0s-cluster-bootstrap

A comprehensive solution for bootstrapping Kubernetes clusters using [k0s](https://k0sproject.io/) with GitOps practices powered by [ArgoCD](https://argo-cd.readthedocs.io/) and secure secret management using [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets).

## 📋 Overview

This repository provides automated scripts and manifest files to:
- Deploy k0s Kubernetes cluster (controller and worker nodes)
- Set up ArgoCD for GitOps-based cluster management
- Configure Sealed Secrets for secure secret management
- Bootstrap your cluster with essential components

## 🏗️ Project Structure

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
│       └── controller.yaml              # Sealed Secrets controller
├── config/
│   └── k0s.yaml                         # K0s cluster configuration
├── secrets/
│   └── examples/
│       └── cloudflare-secret.example    # Example secret template
└── README.md
```

## 🚀 Quick Start

### Prerequisites

- Linux-based operating system (Ubuntu 20.04+ recommended)
- sudo privileges
- curl installed
- At least 2GB RAM and 2 CPU cores

### Step 1: Install k0s Controller

On your controller node:

```bash
cd scripts
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