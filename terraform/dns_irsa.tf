resource "aws_route53_zone" "delegated" {
  name = local.delegated_zone_name

  tags = merge(
    local.common_tags,
    {
      Name = local.delegated_zone_name
    }
  )
}

data "aws_iam_policy_document" "external_dns_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_host}:sub"
      values   = ["system:serviceaccount:external-dns:external-dns"]
    }
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "${local.name_prefix}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "external_dns" {
  statement {
    sid = "AllowRecordManagement"

    actions = [
      "route53:ChangeResourceRecordSets",
    ]

    resources = [aws_route53_zone.delegated.arn]
  }

  statement {
    sid = "AllowZoneDiscovery"

    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
      "route53:GetHostedZone",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "external_dns" {
  name   = "${local.name_prefix}-external-dns"
  policy = data.aws_iam_policy_document.external_dns.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  role       = aws_iam_role.external_dns.name
  policy_arn = aws_iam_policy.external_dns.arn
}

data "aws_iam_policy_document" "cert_manager_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_host}:sub"
      values   = ["system:serviceaccount:cert-manager:cert-manager"]
    }
  }
}

resource "aws_iam_role" "cert_manager" {
  name               = "${local.name_prefix}-cert-manager"
  assume_role_policy = data.aws_iam_policy_document.cert_manager_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "cert_manager" {
  statement {
    sid = "AllowRecordManagement"

    actions = [
      "route53:ChangeResourceRecordSets",
    ]

    resources = [aws_route53_zone.delegated.arn]
  }

  statement {
    sid = "AllowReadOnlyDNS"

    actions = [
      "route53:GetChange",
      "route53:GetHostedZone",
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "cert_manager" {
  name   = "${local.name_prefix}-cert-manager"
  policy = data.aws_iam_policy_document.cert_manager.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cert_manager" {
  role       = aws_iam_role.cert_manager.name
  policy_arn = aws_iam_policy.cert_manager.arn
}
