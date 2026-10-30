# Least-privilege IAM. Policies are built with jsonencode (not the
# aws_iam_policy_document data source) so `terraform test` with mocked providers
# can assert on their exact content.
#
# Task role: Bedrock inference + guardrails only (optional model/region
# allowlists), write-only request-log bucket, read-only config object.
# Execution role: logs, the named secrets, the customer KMS key. No ECR: the
# official upstream image is pulled from ghcr.io (image mirroring is below the
# line), so no registry permissions are needed. No `*` actions anywhere.

locals {
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  # Secrets the execution role may read: strip the optional :json-key:: suffix
  # (name:key::) down to the secret ARN itself.
  all_secret_arns = distinct([
    for v in values(local.container.secrets) :
    regex("^(arn:[^:]+:secretsmanager:[^:]+:[^:]+:secret:[^:]+)", v)[0]
  ])

  execution_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "Logs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${aws_cloudwatch_log_group.litellm.arn}:*"
        },
        {
          Sid      = "Secrets"
          Effect   = "Allow"
          Action   = "secretsmanager:GetSecretValue"
          Resource = local.all_secret_arns
        },
      ],
      var.kms_key_arn != null ? [{
        Sid      = "DecryptWithCustomerKey"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = var.kms_key_arn
      }] : [],
    )
  })

  # Any model and inference profile in any region by default (cross-region
  # inference profiles and new regions work without a redeploy); the optional
  # allowlists narrow it.
  bedrock_regions = length(var.bedrock_region_allowlist) > 0 ? var.bedrock_region_allowlist : ["*"]
  bedrock_model_resources = length(var.bedrock_model_allowlist) > 0 ? flatten([
    for r in local.bedrock_regions : [
      for m in var.bedrock_model_allowlist : [
        "arn:aws:bedrock:${r}::foundation-model/${m}",
        "arn:aws:bedrock:${r}:${data.aws_caller_identity.current.account_id}:inference-profile/*${m}",
      ]
    ]
    ]) : flatten([for r in local.bedrock_regions : [
      "arn:aws:bedrock:${r}::foundation-model/*",
      "arn:aws:bedrock:${r}:*:inference-profile/*",
      "arn:aws:bedrock:${r}:*:application-inference-profile/*",
  ]])

  task_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ReadConfig"
          Effect   = "Allow"
          Action   = "s3:GetObject"
          Resource = "arn:aws:s3:::${var.config_bucket_name}/${local.config_object_key}"
        },
        {
          Sid      = "WriteRequestLogs"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.request_logs.arn}/*"
        },
        {
          Sid    = "BedrockInference"
          Effect = "Allow"
          Action = [
            "bedrock:InvokeModel",
            "bedrock:InvokeModelWithResponseStream",
            "bedrock:Converse",
            "bedrock:ConverseStream",
            "bedrock:CountTokens",
          ]
          Resource = local.bedrock_model_resources
        },
        {
          Sid      = "BedrockGuardrails"
          Effect   = "Allow"
          Action   = "bedrock:ApplyGuardrail"
          Resource = "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:guardrail/*"
        },
      ],
      # Cross-account roles are listed explicitly; wildcards are rejected in variables.tf.
      length(var.cross_account_role_arns) > 0 ? [{
        Sid      = "CrossAccountModels"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = var.cross_account_role_arns
      }] : [],
      var.kms_key_arn != null ? [{
        Sid      = "DecryptConfigAndEncryptLogs"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn
      }] : [],
    )
  })
}

resource "aws_iam_role" "task" {
  name               = "${var.deployment_name}-ecs-task-role"
  assume_role_policy = local.assume_role_policy
}

resource "aws_iam_role" "execution" {
  name               = "${var.deployment_name}-ecs-execution-role"
  assume_role_policy = local.assume_role_policy
}

resource "aws_iam_role_policy" "execution" {
  name   = "${var.deployment_name}-ecs-execution"
  role   = aws_iam_role.execution.id
  policy = local.execution_policy
}

resource "aws_iam_role_policy" "task" {
  name   = "${var.deployment_name}-ecs-task"
  role   = aws_iam_role.task.id
  policy = local.task_policy
}
