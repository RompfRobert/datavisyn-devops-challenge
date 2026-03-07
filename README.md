# Datavisyn DevOps Coding Challenge

Welcome to my solution for the Datavisyn DevOps Challenge. I have implemented two separate approaches to showcase both solid engineering principles and advanced GitOps capabilities.

**Branch Overview:**

1. **`master` (default)** — Reproducible reviewer workflow optimized for maximum accessibility. Uses imperative scripts with local secret input. Any reviewer can clone, run Terraform, and bootstrap the entire stack locally.
2. **`argocd`** — Bonus GitOps implementation demonstrating declarative infrastructure, stable subdomain integration using Route53, and automated reconciliation with ArgoCD. Intended as a capability showcase rather than the primary review path.

## Prerequisites

This guide is designed for **macOS** and **Linux**. Windows users should use [WSL 2](https://learn.microsoft.com/en-us/windows/wsl/install).

**AWS Credentials:**  
Configure your AWS credentials before proceeding. See the [AWS CLI Configuration Guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-quickstart.html).

**Required Tools:**

All of the following tools must be installed:

| Tool | Version | Installation |
|------|---------|--------------|
| **Terraform** | >= 1.5.0 | [Download](https://www.terraform.io/downloads) • [Homebrew](https://formulae.brew.sh/formula/terraform) |
| **kubectl** | >= 1.27 | [Download](https://kubernetes.io/docs/tasks/tools/) • [Homebrew](https://formulae.brew.sh/formula/kubernetes-cli) |
| **Helm** | >= 3.12 | [Download](https://helm.sh/docs/intro/install/) • [Homebrew](https://formulae.brew.sh/formula/helm) |
| **AWS CLI** | v2 | [Download](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) • [Homebrew](https://formulae.brew.sh/formula/awscli) |
| **sops** | >= 3.8 | [GitHub](https://github.com/getsops/sops#installation) • [Homebrew](https://formulae.brew.sh/formula/sops) |
| **GPG** | >= 2.2 | [Download](https://gnupg.org/download/) • [Homebrew](https://formulae.brew.sh/formula/gnupg) |

Verify your installations:

```bash
terraform version && kubectl version --client && helm version && aws --version && sops --version && gpg --version
```

## Getting Started

Clone the repository and enter the directory:

```bash
git clone git@github.com:RompfRobert/datavisyn-devops-challenge.git && cd datavisyn-devops-challenge
```

### Step 1: Provision the EKS Cluster with Terraform

```bash
cd terraform && terraform apply -auto-approve && cd ..
```

> **Note:** Infrastructure provisioning typically takes 10–20 minutes.

Once Terraform completes, configure `kubectl` to access the cluster:

```bash
aws eks update-kubeconfig --region $(terraform -chdir=terraform output -raw region) --name $(terraform -chdir=terraform output -raw cluster_name)
```

**Verify cluster access:**

```bash
kubectl config get-contexts
kubectl get nodes
```

### Step 2: Bootstrap the Application Stack

Automated bootstrap scripts will deploy the Kubernetes infrastructure and application services. The process is divided into two phases:

**Phase 1:** Deploy ingress-nginx, frontend, and backend applications accessible via the dynamically provisioned ELB hostname.

Run:

```bash
./scripts/phase1_bootstrap.sh
```

Wait 2–3 minutes for the load balancer to stabilize, then verify using the `curl` commands or visit the URL in your browser.

**Alternative: Manual Helm Installation**

If you prefer to skip the bootstrap script or install components individually:

```bash
helm upgrade --install backend ./helm/backend -n demo --create-namespace
helm upgrade --install frontend ./helm/frontend -n demo
kubectl get pods,svc -n demo
```

To verify deployment and test locally:

```bash
kubectl port-forward svc/frontend 8080:80 -n demo &
kubectl port-forward svc/backend 8081:80 -n demo &

curl http://localhost:8080
curl http://localhost:8081/test
```

**Phase 2:** Set up OAuth2 authentication using GitHub.

Before running Phase 2, create a GitHub OAuth Application:

1. Go to [GitHub Settings → Developer applications](https://github.com/settings/developers)
2. Click **New OAuth App**
3. Fill in:
   - **Application name:** Any name (e.g., "DevOps Challenge")
   - **Homepage URL:** The ELB URL from Phase 1 output (e.g., `http://<ELB-HOSTNAME>`)
   - **Authorization callback URL:** `http://<ELB-HOSTNAME>/oauth2/callback`
4. Click **Register application**
5. Save the **Client ID** and **Client Secret**

Now run the Phase 2 bootstrap script:

```bash
./scripts/phase2_enable_oauth.sh
```

The script will prompt you to:

- Select or create a GPG key for SOPS encryption
- Enter your GitHub OAuth Client ID and Client Secret
- Confirm the deployment

Once the oauth2-proxy pod is ready (2–3 minutes), open the URL from the output in your browser. You should be redirected to GitHub to authenticate.

## Architecture & Design Decisions

**Demo Configuration Notes:**

- **HTTP Only:** For simplicity in a demo environment, the setup uses HTTP instead of HTTPS. Production deployments would use TLS certificates (via cert-manager and Route53).
- **Cookie Security:** OAuth2 cookies are marked as non-secure (`cookieSecure: false`) to work over HTTP. This is intentional for the demo.
- **Email Domain:** Set to `*` to allow any GitHub user. Restrict this to your organization in production.
- **CLI Access:** After enabling OAuth, browser-based access works; CLI access (curl) returns 302 redirects. In production, add API-level authentication or implement a separate endpoint.

## Bonus: GitOps with ArgoCD

For an advanced declarative approach with stable DNS integration, see the [`argocd` branch](https://github.com/RompfRobert/datavisyn-devops-challenge/tree/argocd). That branch includes:

- Route53 DNS integration with your own domain
- ArgoCD for GitOps-driven deployments
- Stable HTTPS ingress configuration
- Automated certificate management

The `argocd` branch demonstrates enterprise-grade GitOps practices but requires domain ownership and is less reproducible for third-party reviewers.

## Troubleshooting

**Phase 1 hangs waiting for load balancer:**

- AWS can take 5–10 minutes to provision the ELB. The script will retry up to 60 times (10 minutes).
- Manually check: `kubectl -n ingress-nginx get svc ingress-nginx-controller`

**Phase 2 fails with GPG errors:**

- Ensure `gpg` and `sops` are installed and `helm-secrets` plugin was installed in Phase 1.
- Check: `helm plugin list | grep secrets`

**OAuth redirect fails:**

- Confirm the GitHub OAuth App callback URL exactly matches the Phase 1 ELB URL plus `/oauth2/callback`.
- Verify the oauth2-proxy pod is running: `kubectl -n demo get pods -l app=oauth2-proxy`

## Cleanup

To destroy all resources and avoid charges:

```bash
./scripts/reset_cluster.sh
```

```bash
cd terraform && terraform destroy -auto-approve && cd ..
```

This will remove the EKS cluster, VPC, and all associated AWS resources.
