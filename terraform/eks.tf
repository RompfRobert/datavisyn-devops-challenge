module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_private_access      = var.cluster_endpoint_private_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Keep auth simple for demo workflows: Terraform caller gets cluster-admin.
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # Keep the stack minimal for this challenge; disable optional auto-mode custom tag IAM policies.
  enable_auto_mode_custom_tags = false

  # Keep control plane encryption defaults simple (AWS-managed key) to avoid extra KMS resources.
  cluster_encryption_config        = {}
  create_kms_key                   = false
  attach_cluster_encryption_policy = false

  enable_irsa = true

  eks_managed_node_groups = {
    (var.node_group_name) = {
      min_size     = var.node_group_min_size
      max_size     = var.node_group_max_size
      desired_size = var.node_group_desired_size

      instance_types = var.node_instance_types
      capacity_type  = var.node_capacity_type
      disk_size      = var.node_group_disk_size
    }
  }

  tags = local.common_tags
}
