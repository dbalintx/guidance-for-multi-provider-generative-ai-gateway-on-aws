# Plans the example against a mocked AWS provider: the pods' IAM role and its
# Pod Identity binding, the request-log bucket, the rendered config and the
# input validations. Nothing touches AWS or a cluster.
#
#   terraform -chdir=examples/eks/terraform init -backend=false
#   terraform -chdir=examples/eks/terraform test

mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }

  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/llmgw-eks-pod-role" }
  }

  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::llmgw-eks-req-logs-111111111111-eu-west-1" }
  }
}

variables {
  deployment_name = "llmgw"
  cluster_name    = "trial"
  vpc_cidr        = "10.0.0.0/16"
}

run "pod_role_is_bound_to_the_cluster_and_service_account" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.pod.assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com"
    error_message = "Only EKS Pod Identity may assume the pod role."
  }

  assert {
    condition     = toset(jsondecode(aws_iam_role.pod.assume_role_policy).Statement[0].Action) == toset(["sts:AssumeRole", "sts:TagSession"])
    error_message = "Pod Identity needs sts:AssumeRole and sts:TagSession, nothing else."
  }

  assert {
    condition     = jsondecode(aws_iam_role.pod.assume_role_policy).Statement[0].Condition.ArnEquals["aws:SourceArn"] == "arn:aws:eks:eu-west-1:111111111111:cluster/trial"
    error_message = "The trust policy is limited to the one cluster."
  }

  assert {
    condition     = jsondecode(aws_iam_role.pod.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "111111111111"
    error_message = "The trust policy is limited to the account."
  }

  assert {
    condition = (
      aws_eks_pod_identity_association.litellm.cluster_name == "trial" &&
      aws_eks_pod_identity_association.litellm.namespace == "litellm" &&
      aws_eks_pod_identity_association.litellm.service_account == "litellm"
    )
    error_message = "The association binds the role to litellm/litellm on the given cluster."
  }
}

run "pod_policy_is_least_privilege" {
  command = plan

  assert {
    condition = toset(flatten([for s in jsondecode(aws_iam_role_policy.pod.policy).Statement : s.Action])) == toset([
      "s3:PutObject",
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:Converse",
      "bedrock:ConverseStream",
      "bedrock:CountTokens",
      "bedrock:ApplyGuardrail",
    ])
    error_message = "Bedrock inference, guardrails and request-log writes only: no config read, no Secrets Manager, no KMS without a customer key."
  }

  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_role_policy.pod.policy).Statement : !contains(flatten([s.Action]), "*") && s.Effect == "Allow"])
    error_message = "No wildcard actions."
  }

  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.pod.policy).Statement : s.Resource if s.Sid == "WriteRequestLogs"][0] == "arn:aws:s3:::llmgw-eks-req-logs-111111111111-eu-west-1/*"
    error_message = "Request logs are written to the example's own bucket only."
  }

  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.pod.policy).Statement : s.Resource if s.Sid == "BedrockGuardrails"][0] == "arn:aws:bedrock:*:111111111111:guardrail/*"
    error_message = "Guardrails of the own account only."
  }
}

run "customer_key_adds_log_encryption_only" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:111111111111:key/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition = one([for s in jsondecode(aws_iam_role_policy.pod.policy).Statement : s if s.Sid == "EncryptLogs"]) == {
      Sid      = "EncryptLogs"
      Effect   = "Allow"
      Action   = "kms:GenerateDataKey"
      Resource = "arn:aws:kms:eu-west-1:111111111111:key/00000000-0000-0000-0000-000000000000"
    }
    error_message = "With a customer key the pods may only generate data keys for the request logs."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.request_logs.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "The request-log bucket uses the customer key."
  }
}

run "config_is_the_gateway_template" {
  command = plan

  assert {
    condition     = output.config_sha == sha256(output.litellm_config_yaml)
    error_message = "config_sha is the hash of the rendered config."
  }

  assert {
    condition     = yamldecode(output.litellm_config_yaml).litellm_settings.s3_callback_params.s3_bucket_name == "llmgw-eks-req-logs-111111111111-eu-west-1"
    error_message = "The s3 callbacks write to the example's request-log bucket."
  }

  assert {
    condition     = yamldecode(output.litellm_config_yaml).general_settings.trusted_proxy_ranges == ["10.0.0.0/16"]
    error_message = "The trusted proxy range is the VPC CIDR, as in the ECS deployment."
  }

  assert {
    condition = (
      yamldecode(output.litellm_config_yaml).router_settings.redis_host == "os.environ/REDIS_HOST" &&
      yamldecode(output.litellm_config_yaml).litellm_settings.turn_off_message_logging == true
    )
    error_message = "The base template's runtime values come from the environment."
  }

  assert {
    condition     = aws_s3_bucket.request_logs.force_destroy
    error_message = "The example's request-log bucket is removed on teardown."
  }
}

run "rejects_invalid_names" {
  command = plan

  variables {
    name         = "Not_Valid"
    cluster_name = "-bad"
    namespace    = "Bad_NS"
  }

  expect_failures = [var.name, var.cluster_name, var.namespace]
}
