# Terraform: AWS VPC + EKS

This Terraform stack provisions:

- A custom VPC with public/private subnets across 2-3 AZs
- An EKS cluster with one managed node group
- OIDC provider for IRSA

It uses official modules only:

- `terraform-aws-modules/vpc/aws`
- `terraform-aws-modules/eks/aws`

## Prerequisites

- Terraform `>= 1.5.0`
- AWS CLI v2
- `kubectl`
- AWS credentials configured (for example via `aws configure` or SSO profile)

## Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` if needed.

## Deploy

```bash
terraform init
terraform apply
```

## Connect to EKS

Use Terraform outputs to avoid guessing names:

```bash
aws eks update-kubeconfig \
  --region "$(terraform output -raw region)" \
  --name "$(terraform output -raw cluster_name)"
```

Verify nodes:

```bash
kubectl get nodes
```

## Destroy

```bash
terraform destroy
```
