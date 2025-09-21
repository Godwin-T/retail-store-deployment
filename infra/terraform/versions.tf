terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      # version is pinned by .terraform.lock.hcl
    }
    helm = {
      source = "hashicorp/helm"
      # version is pinned by .terraform.lock.hcl
    }
  }
}
