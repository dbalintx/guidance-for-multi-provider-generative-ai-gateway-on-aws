# Input validation rules, run against mocked providers (no credentials, no AWS).

mock_provider "aws" {}
mock_provider "random" {}

variables {
  deployment_name = "llmgw"
}

run "valid_defaults_plan" {
  command = plan
}

run "tracking_stack_carries_solution_id_and_deployment_name" {
  command = plan

  assert {
    condition     = aws_cloudformation_stack.guidance_deployment_metrics.name == "llmgw-tracking-stack"
    error_message = "The tracking stack name must derive from deployment_name so two deployments in one account do not collide."
  }

  assert {
    condition     = strcontains(aws_cloudformation_stack.guidance_deployment_metrics.template_body, "SO9022")
    error_message = "The tracking stack must carry solution ID SO9022 in its description."
  }
}

run "uppercase_deployment_name_rejected" {
  command = plan

  variables {
    deployment_name = "LLMGateway"
  }

  expect_failures = [var.deployment_name]
}

run "overlong_deployment_name_rejected" {
  command = plan

  variables {
    deployment_name = "a-very-long-deployment-name-over-twenty"
  }

  expect_failures = [var.deployment_name]
}

run "invalid_extra_ingress_cidr_rejected" {
  command = plan

  variables {
    extra_data_ingress_cidrs = ["10.0.0.0/8", "not-a-cidr"]
  }

  expect_failures = [var.extra_data_ingress_cidrs]
}

run "invalid_extra_ingress_security_group_rejected" {
  command = plan

  variables {
    extra_data_ingress_security_group_ids = ["subnet-0123456789abcdef0"]
  }

  expect_failures = [var.extra_data_ingress_security_group_ids]
}

run "valid_extra_ingress_accepted" {
  command = plan

  variables {
    extra_data_ingress_cidrs              = ["10.1.0.0/16"]
    extra_data_ingress_security_group_ids = ["sg-0123456789abcdef0"]
  }
}
