variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "bedrock-eks"
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of AZs to use"
  type        = number
  default     = 2
}

variable "node_instance_types" {
  description = "Instance types for managed node groups"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  description = "Node group min size"
  type        = number
  default     = 1
}

variable "node_desired_size" {
  description = "Node group desired size"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Node group max size"
  type        = number
  default     = 2
}

variable "enable_cluster_encryption" {
  description = "Enable EKS secrets envelope encryption with a KMS key"
  type        = bool
  default     = true
}


variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Optional AWS shared credentials profile name"
  type        = string
  default     = null
}

variable "developers_role_name" {
  description = "IAM role name for developers with EKS read-only access"
  type        = string
  default     = "bedrock-developers-eks-readonly"
}
variable "developer_trusted_arns" {
  description = "List of IAM principal ARNs allowed to assume the developers role. Defaults to account root."
  type        = list(string)
  default     = []
}

variable "admin_principal_arns" {
  description = "IAM principal ARNs to grant cluster-admin via EKS Access Entries"
  type        = list(string)
  default     = []
}

variable "istio_enabled" {
  description = "Enable Istio-related security group rules"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags to apply to created resources"
  type        = map(string)
  default     = {}
}
