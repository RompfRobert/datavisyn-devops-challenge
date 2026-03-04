data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name_prefix  = "${var.project_name}-${var.environment}"
  cluster_name = var.cluster_name != "" ? var.cluster_name : "${local.name_prefix}-eks"
  vpc_name     = "${local.name_prefix}-vpc"

  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Split the VPC CIDR into /20 subnets by default (enough for 2-3 AZ public/private layout).
  public_subnet_cidrs  = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index)]
  private_subnet_cidrs = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index + length(local.azs))]

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags
  )
}
