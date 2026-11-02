terraform {
  required_version = ">= 1.11" # write-only arguments; cross-variable validation; S3 native state locking

  # Configured by deploy/deploy.sh (bucket, key, region, encrypt, use_lockfile).
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7, < 4.0" # ephemeral random_password
    }
  }
}

locals {
  common_tags = merge(var.tags, {
    Project            = "llmgateway"
    GithubRepo         = "https://github.com/aws-solutions-library-samples/guidance-for-multi-provider-generative-ai-gateway-on-aws"
    SolutionID         = "SO9022"
    SolutionNameKey    = "Guidance for Running Generative AI Gateway Proxy on AWS"
    SolutionVersionKey = "2.0.0"
    Deployment         = var.deployment_name
    Stack              = "app"
    ManagedBy          = "terraform"
  })
}

provider "aws" {
  default_tags {
    tags = local.common_tags
  }
}
