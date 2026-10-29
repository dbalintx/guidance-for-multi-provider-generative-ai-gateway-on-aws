# Mode validation rules (Milestone 1 contract), run against mocked providers.

mock_provider "aws" {}
mock_provider "random" {}

variables {
  deployment_name = "llmgw"
  certificate_arn = "arn:aws:acm:eu-west-1:111111111111:certificate/00000000-0000-0000-0000-000000000000"
}

run "private_with_certificate_plans" {
  command = plan
}

run "http_only_private_trial_plans" {
  command = plan

  variables {
    certificate_arn     = null
    allow_insecure_http = true
  }
}

run "missing_certificate_rejected" {
  command = plan

  variables {
    certificate_arn = null
  }

  expect_failures = [var.certificate_arn]
}

run "insecure_http_in_public_mode_rejected" {
  command = plan

  variables {
    certificate_arn     = null
    allow_insecure_http = true
    public_mode         = true
  }

  expect_failures = [var.allow_insecure_http]
}

run "zone_without_name_rejected" {
  command = plan

  variables {
    hosted_zone_id = "Z0123456789ABCDEFGHIJ"
  }

  expect_failures = [var.record_name]
}

run "name_without_zone_rejected" {
  command = plan

  variables {
    record_name = "llm.example.com"
  }

  expect_failures = [var.record_name]
}

run "zone_with_name_plans" {
  command = plan

  variables {
    hosted_zone_id = "Z0123456789ABCDEFGHIJ"
    record_name    = "llm.example.com"
  }
}

run "identity_provider_with_insecure_http_rejected" {
  command = plan

  variables {
    certificate_arn     = null
    allow_insecure_http = true
    identity_provider = {
      issuer                 = "https://login.example.com/tenant/v2.0"
      authorization_endpoint = "https://login.example.com/tenant/oauth2/v2.0/authorize"
      token_endpoint         = "https://login.example.com/tenant/oauth2/v2.0/token"
      user_info_endpoint     = "https://graph.example.com/oidc/userinfo"
      client_id              = "00000000-0000-0000-0000-000000000000"
      client_secret_arn      = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/idp-AbCdEf"
    }
  }

  expect_failures = [var.identity_provider]
}

run "identity_provider_with_https_plans_in_private_mode" {
  command = plan

  variables {
    identity_provider = {
      issuer                 = "https://login.example.com/tenant/v2.0"
      authorization_endpoint = "https://login.example.com/tenant/oauth2/v2.0/authorize"
      token_endpoint         = "https://login.example.com/tenant/oauth2/v2.0/token"
      user_info_endpoint     = "https://graph.example.com/oidc/userinfo"
      client_id              = "00000000-0000-0000-0000-000000000000"
      client_secret_arn      = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/idp-AbCdEf"
    }
  }
}
