locals {
  cart_namespace            = "retail"
  cart_service_account      = "carts-sa"
  cart_service_account_sub  = "system:serviceaccount:${local.cart_namespace}:${local.cart_service_account}"
}

# Resolve OIDC issuer URL and build proper condition keys
data "aws_iam_openid_connect_provider" "eks" {
  arn = module.eks.oidc_provider_arn
}

locals {
  oidc_hostpath = replace(data.aws_iam_openid_connect_provider.eks.url, "https://", "")
}

data "aws_iam_policy_document" "cart_irsa_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_hostpath}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_hostpath}:sub"
      values   = [local.cart_service_account_sub]
    }
  }
}

resource "aws_iam_role" "cart_irsa" {
  name               = "${var.cluster_name}-cart-irsa"
  assume_role_policy = data.aws_iam_policy_document.cart_irsa_assume.json
  description        = "IRSA role for carts service to access DynamoDB"
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cart_dynamo_access" {
  role       = aws_iam_role.cart_irsa.name
  # Use v2 dependencies policy when running without the dependencies module
  policy_arn = aws_iam_policy.carts_dynamo_v2.arn
}
