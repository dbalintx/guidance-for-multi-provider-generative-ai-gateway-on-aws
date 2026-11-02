# Generated-secret rotation and salt-key protection, applied against a mocked
# AWS provider (no credentials, no AWS) with the real, local random provider
# (mock providers do not support ephemeral resources). Only the secrets are
# applied, so unrelated resources need no realistic mock values.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b"] }
  }
  mock_data "aws_vpc_endpoint" {
    defaults = { id = "vpce-1" }
  }
}

provider "random" {}

variables {
  deployment_name = "llmgw"
}

run "secrets_created_at_version_1" {
  command = apply

  plan_options {
    target = [
      aws_secretsmanager_secret_version.master_key,
      aws_secretsmanager_secret_version.salt_key,
      aws_secretsmanager_secret_version.ui_password,
    ]
  }

  assert {
    condition     = aws_secretsmanager_secret_version.master_key.secret_string_wo_version == 1 && aws_secretsmanager_secret_version.salt_key.secret_string_wo_version == 1
    error_message = "Generated secrets are created at version 1."
  }
}

run "rotation_never_rewrites_the_salt_key" {
  command = apply

  variables {
    generated_secrets_version = 2
  }

  plan_options {
    target = [
      aws_secretsmanager_secret_version.master_key,
      aws_secretsmanager_secret_version.salt_key,
      aws_secretsmanager_secret_version.ui_password,
    ]
  }

  assert {
    condition     = aws_secretsmanager_secret_version.master_key.secret_string_wo_version == 2 && aws_secretsmanager_secret_version.ui_password.secret_string_wo_version == 2
    error_message = "Bumping generated_secrets_version must re-send the master key and UI password."
  }

  assert {
    condition     = aws_secretsmanager_secret_version.salt_key.secret_string_wo_version == 1
    error_message = "The salt key must never be re-sent: rotating it makes every stored provider credential unreadable."
  }
}

run "fractional_secrets_version_rejected" {
  command = plan

  variables {
    generated_secrets_version = 1.5
  }

  expect_failures = [var.generated_secrets_version]
}
