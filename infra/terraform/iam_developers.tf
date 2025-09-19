# data "aws_caller_identity" "current" {}

locals {
  developers_trusted_default = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  ]
  developers_trusted_arns = length(var.developer_trusted_arns) > 0 ? var.developer_trusted_arns : local.developers_trusted_default
}

data "aws_iam_policy_document" "developers_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = local.developers_trusted_arns
    }
    actions = [
      "sts:AssumeRole"
    ]
  }
}

resource "aws_iam_role" "developers" {
  name               = var.developers_role_name
  assume_role_policy = data.aws_iam_policy_document.developers_trust.json
  description        = "Role for developers to access EKS cluster (read-only kubectl)"
  force_detach_policies = true
}

# Read-only permissions to EKS API (Describe* etc.) so update-kubeconfig works
resource "aws_iam_role_policy_attachment" "developers_readonly" {
  role       = aws_iam_role.developers.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Grant Kubernetes RBAC access using EKS Access Entries (view-only at cluster scope)
resource "aws_eks_access_entry" "developers" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.developers.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "developers_view" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.developers.arn

  # View-only cluster access policy
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type = "cluster"
  }
}
