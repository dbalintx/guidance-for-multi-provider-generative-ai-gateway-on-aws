terraform {
  required_version = ">= 1.11"

  # Configured by scripts/deploy.sh (bucket, key, region, encrypt, use_lockfile).
  backend "s3" {}

  # The AWS provider only: the Kubernetes objects are plain manifests applied
  # with kubectl by scripts/deploy.sh, never by Terraform.
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}

provider "aws" {
  default_tags {
    tags = merge(var.tags, {
      Project   = "llmgateway"
      Example   = "eks"
      ManagedBy = "terraform"
    })
  }
}
