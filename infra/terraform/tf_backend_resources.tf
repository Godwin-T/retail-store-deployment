###############################################
# Terraform remote state backend (optional)
# Creates S3 bucket + DynamoDB lock table when
# var.manage_backend = true
###############################################

locals {
  backend_tags = merge(
    {
      Managed = "terraform"
      Project = "project-bedrock"
      Purpose = "terraform-state"
    },
    var.tags
  )
}

resource "aws_s3_bucket" "tf_state" {
  count  = var.manage_backend ? 1 : 0
  bucket = var.tf_state_bucket_name
  tags   = local.backend_tags
}

resource "aws_s3_bucket_versioning" "tf_state" {
  count  = var.manage_backend ? 1 : 0
  bucket = aws_s3_bucket.tf_state[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  count                   = var.manage_backend ? 1 : 0
  bucket                  = aws_s3_bucket.tf_state[0].id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  count  = var.manage_backend ? 1 : 0
  bucket = aws_s3_bucket.tf_state[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_dynamodb_table" "tf_state_locks" {
  count        = var.manage_backend ? 1 : 0
  name         = var.tf_state_lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = local.backend_tags
}

