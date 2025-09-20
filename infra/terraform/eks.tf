module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  providers = {
    kubernetes = kubernetes.cluster
  }

  cluster_name                   = var.cluster_name
  cluster_version                = var.cluster_version
  cluster_endpoint_public_access = true
  cluster_endpoint_private_access = false
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    vpc-cni = {
      before_compute = true
      most_recent    = true
      configuration_values = jsonencode({
        env = {
          ENABLE_POD_ENI                    = "true"
          POD_SECURITY_GROUP_ENFORCING_MODE = "standard"
        }
      })
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets # per requirement, place EKS in public subnets

  enable_irsa    = true
  create_kms_key = var.enable_cluster_encryption

  cluster_encryption_config = var.enable_cluster_encryption ? {
    resources = ["secrets"]
  } : null

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size

      subnet_ids = module.vpc.public_subnets

      iam_role_additional_policies = {
        ecr_readonly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
      }    
    }
  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }

    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }

    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  tags = var.tags
}

resource "aws_security_group_rule" "dns_udp" {
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = module.eks.node_security_group_id
}

resource "aws_security_group_rule" "dns_tcp" {
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = module.eks.node_security_group_id
}

resource "aws_security_group_rule" "istio" {
  count = var.istio_enabled ? 1 : 0

  type              = "ingress"
  from_port         = 15012
  to_port           = 15012
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = module.eks.node_security_group_id
}

resource "aws_security_group_rule" "istio_webhook" {
  count = var.istio_enabled ? 1 : 0

  type              = "ingress"
  from_port         = 15017
  to_port           = 15017
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = module.eks.node_security_group_id
}

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  providers = {
    kubernetes = kubernetes.cluster
    helm       = helm.cluster
  }

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  enable_aws_load_balancer_controller = true
  # Disable cert-manager when outbound internet is restricted
  enable_cert_manager                 = true
}

resource "time_sleep" "addons" {
  create_duration  = "30s"
  destroy_duration = "30s"

  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "null_resource" "cluster_blocker" {
  depends_on = [
    module.eks
  ]
}

resource "null_resource" "addons_blocker" {
  depends_on = [
    time_sleep.addons,
    # Wait for addons time sleep to complete
  ]
}
