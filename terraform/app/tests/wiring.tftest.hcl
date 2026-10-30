# Key wiring of the app root module, applied against mocked providers: ALB modes,
# OIDC, WAF, the container/migration task definitions, IAM scoping and the
# rendered config. Nothing touches AWS.

# The generated mock values must pass the provider's client-side ARN validation
# where resources reference each other's ARNs.
mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111111111111:role/mock-role"
    }
  }

  mock_resource "aws_lb" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:111111111111:loadbalancer/app/mock/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:111111111111:targetgroup/mock/0123456789abcdef"
    }
  }

  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:eu-west-1:111111111111:listener/app/mock/0123456789abcdef/0123456789abcdef"
    }
  }

  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:eu-west-1:111111111111:regional/webacl/mock/00000000-0000-0000-0000-000000000000"
    }
  }

  # The observability module's policy documents and the ARNs its topic and key
  # policy reference must look real to the provider's client-side validation.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{}"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:eu-west-1:111111111111:llmgw-alarms"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:eu-west-1:111111111111:key/00000000-0000-0000-0000-000000000000"
    }
  }
}
mock_provider "random" {}

variables {
  deployment_name = "llmgw"
  certificate_arn = "arn:aws:acm:eu-west-1:111111111111:certificate/00000000-0000-0000-0000-000000000000"

  # Foundation outputs (wired by deploy.sh in real runs).
  vpc_id                         = "vpc-0123456789abcdef0"
  private_subnet_ids             = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  vpc_cidr                       = "10.0.0.0/16"
  db_endpoint                    = "llmgw-db.cluster.eu-west-1.rds.amazonaws.com:5432"
  database_url_secret_arn        = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/database-url-AbCdEf"
  redis_endpoint                 = "llmgw-redis.cache.amazonaws.com"
  redis_port                     = 6379
  redis_auth_secret_arn          = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/redis-auth-AbCdEf"
  config_bucket_name             = "llmgw-config-111111111111-eu-west-1"
  master_key_secret_arn          = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/master-key-AbCdEf"
  salt_key_secret_arn            = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/salt-key-AbCdEf"
  data_ingress_security_group_id = "sg-0123456789abcdef0"
  ui_password_secret_arn         = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/ui-password-AbCdEf"
  rds_instance_identifier        = "llmgw-litellm-db"
  redis_replication_group_id     = "llmgw-redis"

  # One provider key with the :json-key:: suffix, to prove the execution role
  # grant is on the secret ARN itself.
  provider_secret_arns = {
    OPENAI_API_KEY = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/openai-AbCdEf:api_key::"
  }

  # Never let a test apply run the local-exec migration helper.
  run_migrations_on_apply = false
}

run "private_defaults" {
  command = apply

  assert {
    condition     = aws_lb.this.internal == true
    error_message = "Private mode must create an internal ALB."
  }

  assert {
    condition     = toset(aws_lb.this.subnets) == toset(var.private_subnet_ids)
    error_message = "The internal ALB must live in the private subnets."
  }

  assert {
    condition     = aws_lb.this.idle_timeout == 120 && aws_lb_target_group.litellm.deregistration_delay == "120" && jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].stopTimeout == 120
    error_message = "ALB idle timeout, target deregistration delay and ECS stopTimeout must all be 120 s (5.2)."
  }

  assert {
    condition     = length(aws_lb_listener.https) == 1 && [for a in aws_lb_listener.http.default_action : a.type][0] == "redirect"
    error_message = "HTTPS must be served and plain HTTP redirected to it."
  }

  assert {
    condition     = length(aws_wafv2_web_acl.this) == 0 && length(aws_wafv2_web_acl_association.alb) == 0
    error_message = "No WAF in private mode (2.5)."
  }

  assert {
    condition     = length(aws_lb_listener_rule.ui_oidc) == 0
    error_message = "No OIDC rule without an identity provider."
  }

  assert {
    condition     = keys({ for k, v in aws_vpc_security_group_ingress_rule.alb : k => v }) == ["10.0.0.0/16-443", "10.0.0.0/16-80"]
    error_message = "Private mode must admit the VPC CIDR only, on 80 and 443."
  }

  assert {
    condition     = aws_ecs_service.litellm.deployment_circuit_breaker[0].enable && aws_ecs_service.litellm.deployment_circuit_breaker[0].rollback
    error_message = "The deployment circuit breaker with rollback must be on (5.2)."
  }

  assert {
    condition     = contains(tolist(aws_ecs_service.litellm.network_configuration[0].security_groups), var.data_ingress_security_group_id)
    error_message = "Service tasks must join the foundation's data-ingress security group."
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].image == "ghcr.io/berriai/litellm:v1.106.6"
    error_message = "The service must run the pinned official upstream image."
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].environment : e.name => e.value }["DISABLE_SCHEMA_UPDATE"] == "true"
    error_message = "Service tasks must run DISABLE_SCHEMA_UPDATE=true (5.1)."
  }

  assert {
    condition = alltrue([
      { for e in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].environment : e.name => e.value }["LITELLM_LOG"] == "INFO",
      { for e in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].environment : e.name => e.value }["JSON_LOGS"] == "True",
    ])
    error_message = "Safe logging defaults: INFO level, JSON logs (2.11)."
  }

  assert {
    condition     = strcontains(join(" ", jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].healthCheck.command), "/health/liveliness")
    error_message = "The container must have a real health check against the liveliness path (5.2)."
  }

  assert {
    condition     = !contains([for s in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].secrets : s.name], "LITELLM_LICENSE")
    error_message = "LITELLM_LICENSE must not be set without a licence secret (2.9)."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].secrets :
      s.name == "DATABASE_URL" && s.valueFrom == var.database_url_secret_arn
    ])
    error_message = "DATABASE_URL must come from the foundation's Secrets Manager ARN."
  }

  assert {
    condition     = contains(jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].command, "--skip_server_startup")
    error_message = "The migration task must run --skip_server_startup (5.1)."
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].environment : e.name => e.value }["DISABLE_SCHEMA_UPDATE"] == "false"
    error_message = "Only the one-off migration task may migrate the schema (5.1)."
  }

  assert {
    condition     = !strcontains(jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].name, "LiteLLMContainer") && !can(jsondecode(aws_ecs_task_definition.migrate.container_definitions)[0].healthCheck)
    error_message = "The migration task is a one-off: no service health check."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.task.policy, "bedrock:InvokeModel") && !strcontains(aws_iam_role_policy.task.policy, "\"bedrock:*\"") && !strcontains(aws_iam_role_policy.task.policy, "\"Action\":\"*\"")
    error_message = "Task role: Bedrock inference + guardrails only, never bedrock:* (2.13)."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.task.policy, "arn:aws:s3:::${var.config_bucket_name}/config.yaml") && !strcontains(aws_iam_role_policy.task.policy, "s3:GetObject\",\"s3:PutObject")
    error_message = "Task role: read-only on the config object, write-only on the request logs (2.13)."
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.execution.policy, "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/openai-AbCdEf") && !strcontains(aws_iam_role_policy.execution.policy, "api_key::")
    error_message = "Execution role secret grants must be on the secret ARN, stripped of the :json-key:: suffix."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.execution.policy, "ecr:")
    error_message = "No ECR permissions: the image is pulled from ghcr.io (mirroring is below the line)."
  }

  assert {
    condition     = strcontains(aws_s3_object.litellm_config.content, "10.0.0.0/16") && strcontains(aws_s3_object.litellm_config.content, "trusted_proxy_ranges")
    error_message = "The rendered config must trust the ALB hop via trusted_proxy_ranges = [vpc_cidr] (2.17)."
  }

  assert {
    condition     = strcontains(aws_s3_object.litellm_config.content, "turn_off_message_logging") && !strcontains(aws_s3_object.litellm_config.content, "gpt-4o")
    error_message = "Message logging must be off (2.11) and the default model list off by default (2.17)."
  }

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].environment : e.name => e.value }["LITELLM_CONFIG_SHA"] == sha256(aws_s3_object.litellm_config.content)
    error_message = "The task definition must carry the config content hash, so a config change rolls tasks (2.17)."
  }

  assert {
    condition     = aws_appautoscaling_target.litellm.min_capacity == 2 && aws_appautoscaling_target.litellm.max_capacity == 4
    error_message = "Auto scaling bounds must follow min/max_capacity."
  }

  assert {
    condition     = aws_cloudwatch_log_group.litellm.retention_in_days == 90
    error_message = "90-day log retention by default (2.11)."
  }

  assert {
    condition     = [for s in aws_ecs_cluster.this.setting : s.value if s.name == "containerInsights"][0] == "enabled"
    error_message = "Container Insights must be enabled."
  }

  assert {
    condition     = length(aws_route53_record.alb_alias) == 0
    error_message = "No DNS record without a hosted zone."
  }
}

run "rendered_config_has_no_models_by_default" {
  command = apply

  assert {
    condition     = length(yamldecode(aws_s3_object.litellm_config.content).model_list) == 0
    error_message = "Without config_override_file the rendered config must carry no models (they are added in the LiteLLM UI)."
  }
}

run "public_mode_wiring" {
  command = apply

  variables {
    public_mode       = true
    public_subnet_ids = ["subnet-0fedcba9876543210", "subnet-0fedcba9876543211"]
  }

  assert {
    condition     = aws_lb.this.internal == false && toset(aws_lb.this.subnets) == toset(var.public_subnet_ids)
    error_message = "Public mode must create an internet-facing ALB in the public subnets."
  }

  assert {
    condition     = length(aws_wafv2_web_acl.this) == 1 && length(aws_wafv2_web_acl_association.alb) == 1
    error_message = "Public mode must attach the WAF (2.5)."
  }

  assert {
    condition = anytrue([
      for r in aws_wafv2_web_acl.this[0].rule : anytrue([
        for o in r.statement[0].managed_rule_group_statement[0].rule_action_override :
        o.name == "SizeRestrictions_BODY" && length(o.action_to_use[0].count) == 1
      ]) if r.name == "AWSManagedRulesCommonRuleSet"
    ])
    error_message = "The WAF body-size rule must stay count-only: LLM requests exceed its 8 KB limit (2.5)."
  }

  assert {
    condition     = contains([for k, v in aws_vpc_security_group_ingress_rule.alb : v.cidr_ipv4], "0.0.0.0/0")
    error_message = "Public mode admits the internet; the WAF and LiteLLM auth gate it."
  }
}

run "public_mode_needs_public_subnets" {
  command = plan

  variables {
    public_mode = true
  }

  expect_failures = [var.public_subnet_ids]
}

run "oidc_applied_in_private_mode" {
  command = apply

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

  assert {
    condition     = length(aws_lb_listener_rule.ui_oidc) == 1
    error_message = "An identity provider must put the OIDC action in front of the UI in private mode too (decisions.md)."
  }

  assert {
    condition     = anytrue([for c in aws_lb_listener_rule.ui_oidc[0].condition : contains(tolist(tolist(c.path_pattern)[0].values), "/ui/*")]) && [for a in aws_lb_listener_rule.ui_oidc[0].action : a.type][0] == "authenticate-oidc"
    error_message = "The OIDC action must cover the UI/sign-in paths only; API paths stay on LiteLLM auth."
  }
}

run "oidc_applied_in_public_mode" {
  command = apply

  variables {
    public_mode       = true
    public_subnet_ids = ["subnet-0fedcba9876543210", "subnet-0fedcba9876543211"]
    identity_provider = {
      issuer                 = "https://login.example.com/tenant/v2.0"
      authorization_endpoint = "https://login.example.com/tenant/oauth2/v2.0/authorize"
      token_endpoint         = "https://login.example.com/tenant/oauth2/v2.0/token"
      user_info_endpoint     = "https://graph.example.com/oidc/userinfo"
      client_id              = "00000000-0000-0000-0000-000000000000"
      client_secret_arn      = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/idp-AbCdEf"
    }
  }

  assert {
    condition     = length(aws_lb_listener_rule.ui_oidc) == 1
    error_message = "The OIDC action applies unconditionally in both modes (decisions.md)."
  }
}

run "insecure_http_trial_wiring" {
  command = apply

  variables {
    certificate_arn     = null
    allow_insecure_http = true
  }

  assert {
    condition     = length(aws_lb_listener.https) == 0 && [for a in aws_lb_listener.http.default_action : a.type][0] == "forward"
    error_message = "The HTTP-only trial forwards port 80 straight to LiteLLM, with no HTTPS listener."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb) == 1 && values(aws_vpc_security_group_ingress_rule.alb)[0].from_port == 80
    error_message = "The HTTP-only trial must open port 80 only."
  }

  assert {
    condition     = startswith(output.service_url, "http://")
    error_message = "The trial's service URL is plain http://."
  }
}

run "client_cidrs_replace_vpc_default" {
  command = apply

  variables {
    client_cidrs = ["10.20.0.0/16", "192.168.10.0/24"]
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb) == 4 && !contains([for k, v in aws_vpc_security_group_ingress_rule.alb : v.cidr_ipv4], "10.0.0.0/16")
    error_message = "Listed client CIDRs must replace (not extend) the VPC-CIDR default."
  }
}

run "licence_and_ui_password_wired" {
  command = apply

  variables {
    litellm_license_secret_arn = "arn:aws:secretsmanager:eu-west-1:111111111111:secret:llmgw/licence-AbCdEf"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].secrets :
      s.name == "LITELLM_LICENSE" && s.valueFrom == var.litellm_license_secret_arn
    ])
    error_message = "LITELLM_LICENSE must be wired exactly when the licence secret is given (2.9)."
  }

  # The foundation always generates the UI password, so it is wired like the
  # other foundation secrets — never the master-key fallback (2.12).
  assert {
    condition = anytrue([
      for s in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].secrets :
      s.name == "UI_PASSWORD" && s.valueFrom == var.ui_password_secret_arn
    ])
    error_message = "The foundation's UI password secret must reach the container as UI_PASSWORD (2.12)."
  }

  assert {
    condition     = contains(one([for st in jsondecode(aws_iam_role_policy.execution.policy).Statement : st.Resource if st.Sid == "Secrets"]), var.ui_password_secret_arn)
    error_message = "The execution role must be able to read the UI password secret."
  }
}

run "route53_alias_wiring" {
  command = apply

  variables {
    hosted_zone_id = "Z0123456789ABCDEFGHIJ"
    record_name    = "llm.example.com"
  }

  assert {
    condition     = length(aws_route53_record.alb_alias) == 1 && aws_route53_record.alb_alias[0].name == "llm.example.com"
    error_message = "hosted_zone_id + record_name must create the alias record."
  }

  assert {
    condition     = output.service_url == "https://llm.example.com"
    error_message = "The service URL must prefer the alias record."
  }
}

run "bedrock_allowlists_narrow_iam" {
  command = apply

  variables {
    bedrock_model_allowlist  = ["anthropic.claude-sonnet-4-5-20250929-v1:0"]
    bedrock_region_allowlist = ["eu-west-1"]
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.task.policy, "arn:aws:bedrock:eu-west-1::foundation-model/anthropic.claude-sonnet-4-5-20250929-v1:0") && !strcontains(aws_iam_role_policy.task.policy, "foundation-model/*")
    error_message = "Model and region allowlists must narrow the Bedrock resources (2.13)."
  }
}

run "cross_account_wildcard_rejected" {
  command = plan

  variables {
    cross_account_role_arns = ["arn:aws:iam::222222222222:role/*"]
  }

  expect_failures = [var.cross_account_role_arns]
}

run "debug_log_level_warns" {
  command = apply

  variables {
    log_level = "DEBUG"
  }

  # The check block emits a warning (not an error): the apply must still succeed.
  expect_failures = [check.debug_logging_is_temporary]

  assert {
    condition     = { for e in jsondecode(aws_ecs_task_definition.litellm.container_definitions)[0].environment : e.name => e.value }["LITELLM_LOG"] == "DEBUG"
    error_message = "DEBUG is allowed temporarily; the plan warning is the guard (2.11)."
  }
}

run "no_sg_ingress_without_vpn_or_client_groups" {
  command = apply

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_from_sg) == 0
    error_message = "No security-group ingress on the ALB unless a VPN or client groups are given."
  }
}

run "foundation_vpn_security_group_admitted_to_alb" {
  command = apply

  variables {
    vpn_security_group_id     = "sg-0aaaaaaaaaaaaaaa1"
    client_security_group_ids = ["sg-0bbbbbbbbbbbbbbb2"]
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_from_sg["sg-0aaaaaaaaaaaaaaa1"].referenced_security_group_id == "sg-0aaaaaaaaaaaaaaa1" && aws_vpc_security_group_ingress_rule.alb_from_sg["sg-0aaaaaaaaaaaaaaa1"].from_port == 443
    error_message = "The foundation's VPN security group must reach the ALB's HTTPS listener."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.alb_from_sg) == 2
    error_message = "The VPN security group must add to (not replace) client_security_group_ids."
  }
}

