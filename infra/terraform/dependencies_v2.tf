# Ensure EKS exists first so SG references/allow rules are valid
locals {
  env_name = var.cluster_name
}

##############################
# Shared lookups
##############################
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  aws_account_id = data.aws_caller_identity.current.account_id
  aws_region     = data.aws_region.current.id
  aws_partition  = data.aws_partition.current.id
}

##############################
# Catalog Aurora MySQL (Aurora module)
##############################
resource "random_string" "catalog_db_master_v2" {
  length  = 10
  special = false
}

module "catalog_rds_v2" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "7.7.1"

  name                        = "${local.env_name}-catalog"
  engine                      = "aurora-mysql"
  engine_version              = "8.0"
  instance_class              = "db.t3.medium"
  allow_major_version_upgrade = true

  instances = { one = {} }

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  allowed_security_groups = concat([], [module.eks.node_security_group_id])

  master_password        = random_string.catalog_db_master_v2.result
  create_random_password = false
  database_name          = "catalog"
  storage_encrypted      = true
  apply_immediately      = true
  skip_final_snapshot    = true

  create_db_parameter_group = true
  db_parameter_group_name   = "${local.env_name}-catalog"
  db_parameter_group_family = "aurora-mysql8.0"

  create_db_cluster_parameter_group = true
  db_cluster_parameter_group_name   = "${local.env_name}-catalog"
  db_cluster_parameter_group_family = "aurora-mysql8.0"

  tags = var.tags

  depends_on = [module.eks]
}

##############################
# Orders Aurora Postgres (Aurora module)
##############################
resource "random_string" "orders_db_master_v2" {
  length  = 10
  special = false
}

module "orders_rds_v2" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "7.7.1"

  name           = "${local.env_name}-orders"
  engine         = "aurora-postgresql"
  engine_version = "15.10"
  instance_class = "db.t3.medium"

  instances = { one = {} }

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  allowed_security_groups = concat([], [module.eks.node_security_group_id])

  master_password        = random_string.orders_db_master_v2.result
  create_random_password = false
  database_name          = "orders"
  storage_encrypted      = true
  apply_immediately      = true
  skip_final_snapshot    = true

  create_db_parameter_group = true
  db_parameter_group_name   = "${local.env_name}-orders"
  db_parameter_group_family = "aurora-postgresql15"

  create_db_cluster_parameter_group = true
  db_cluster_parameter_group_name   = "${local.env_name}-orders"
  db_cluster_parameter_group_family = "aurora-postgresql15"

  tags = var.tags

  depends_on = [module.eks]
}

##############################
# DynamoDB for carts + IAM policy
##############################
module "dynamodb_carts_v2" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "3.3.0"

  name     = "${local.env_name}-carts"
  hash_key = "id"

  attributes = [
    { name = "id",         type = "S" },
    { name = "customerId", type = "S" }
  ]

  global_secondary_indexes = [
    {
      name            = "idx_global_customerId"
      hash_key        = "customerId"
      projection_type = "ALL"
    }
  ]

  tags = var.tags

  depends_on = [module.eks]
}

resource "aws_iam_policy" "carts_dynamo_v2" {
  name        = "${local.env_name}-carts-dynamo"
  path        = "/"
  description = "Dynamo policy for carts application"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllAPIActionsOnCart",
      "Effect": "Allow",
      "Action": "dynamodb:*",
      "Resource": [
        "arn:${local.aws_partition}:dynamodb:${local.aws_region}:${local.aws_account_id}:table/${module.dynamodb_carts_v2.dynamodb_table_id}",
        "arn:${local.aws_partition}:dynamodb:${local.aws_region}:${local.aws_account_id}:table/${module.dynamodb_carts_v2.dynamodb_table_id}/index/*"
      ]
    }
  ]
}
EOF

  tags = var.tags
}

##############################
# Amazon MQ (RabbitMQ) for orders
##############################
locals {
  mq_default_user_v2      = "default_mq_user"
  mq_allowed_sgs_v2       = [module.eks.node_security_group_id]
}

resource "random_password" "mq_password_v2" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_+{}<>?"
}

resource "aws_security_group" "mq_v2" {
  name        = "${local.env_name}-orders-broker"
  vpc_id      = module.vpc.vpc_id
  description = "Secure traffic to Rabbit MQ"

  tags = merge(var.tags, { Name = "${local.env_name}-orders-broker" })

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group_rule" "mq_ingress_v2" {
  count = length(local.mq_allowed_sgs_v2)

  type              = "ingress"
  from_port         = 5671
  to_port           = 5671
  protocol          = "tcp"
  security_group_id = aws_security_group.mq_v2.id

  source_security_group_id = local.mq_allowed_sgs_v2[count.index]
}

resource "aws_mq_broker" "mq_v2" {
  broker_name = "${local.env_name}-orders-broker"

  engine_type                = "RabbitMQ"
  engine_version             = "3.13"
  host_instance_type         = "mq.t3.micro"
  deployment_mode            = "SINGLE_INSTANCE"
  subnet_ids                 = [module.vpc.private_subnets[0]]
  security_groups            = [aws_security_group.mq_v2.id]
  apply_immediately          = true
  publicly_accessible        = false
  auto_minor_version_upgrade = true

  user {
    username = local.mq_default_user_v2
    password = random_password.mq_password_v2.result
  }

  tags = var.tags
}

##############################
# ElastiCache Redis for checkout
##############################
module "checkout_elasticache_redis_v2" {
  source  = "cloudposse/elasticache-redis/aws"
  version = "0.53.0"

  name                       = "${local.env_name}-checkout"
  vpc_id                     = module.vpc.vpc_id
  instance_type              = "cache.t3.micro"
  subnets                    = module.vpc.private_subnets
  transit_encryption_enabled = false
  tags                       = var.tags

  allowed_security_group_ids = [module.eks.node_security_group_id]
}

