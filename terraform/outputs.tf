output "region" {
  description = "AWS region used for this deployment."
  value       = var.region
}

output "vpc_id" {
  description = "VPC ID created for the EKS cluster."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "Private subnet IDs used by EKS nodes."
  value       = module.vpc.private_subnets
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "EKS cluster Kubernetes version."
  value       = module.eks.cluster_version
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN created for IRSA."
  value       = module.eks.oidc_provider_arn
}

output "oidc_issuer_url" {
  description = "EKS OIDC issuer URL."
  value       = module.eks.cluster_oidc_issuer_url
}

output "node_group_names" {
  description = "Created EKS managed node group names."
  value       = try([for ng in module.eks.eks_managed_node_groups : ng.node_group_name], keys(module.eks.eks_managed_node_groups))
}

output "delegated_zone_name" {
  description = "Delegated Route53 hosted zone name (for example: challenge.rompf.dev)."
  value       = aws_route53_zone.delegated.name
}

output "delegated_zone_id" {
  description = "Route53 hosted zone ID for the delegated subdomain."
  value       = aws_route53_zone.delegated.zone_id
}

output "delegated_zone_name_servers" {
  description = "Route53 nameservers to configure as NS records for subdomain delegation at your registrar."
  value       = aws_route53_zone.delegated.name_servers
}

output "app_host" {
  description = "Public app hostname used for frontend/backend/oauth2-proxy ingress."
  value       = local.app_host
}

output "argocd_host" {
  description = "Public ArgoCD hostname."
  value       = local.argocd_host
}

output "external_dns_role_arn" {
  description = "IAM role ARN for ExternalDNS IRSA service account annotation."
  value       = aws_iam_role.external_dns.arn
}

output "cert_manager_role_arn" {
  description = "IAM role ARN for cert-manager IRSA service account annotation."
  value       = aws_iam_role.cert_manager.arn
}
