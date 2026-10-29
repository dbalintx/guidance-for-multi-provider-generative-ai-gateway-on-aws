terraform {
  required_version = ">= 1.10" # cross-variable validation, matching the root modules

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}
