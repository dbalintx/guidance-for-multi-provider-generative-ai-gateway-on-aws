# The pods' IAM role through EKS Pod Identity: the equivalent of the ECS task
# role (terraform/app/iam.tf) with its default scope — Bedrock inference and
# guardrails, and write-only access to the request-log bucket. No config read
# (the config arrives as a ConfigMap) and no Secrets Manager access (the
# secrets arrive as a Kubernetes Secret written by scripts/deploy.sh).
# jsonencode, not aws_iam_policy_document, so the tests can assert on content.

locals {
  # Confused-deputy guard: only EKS Pod Identity, for this account and this
  # cluster, may assume the role. The association below binds it to one
  # namespace and service account.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnEquals    = { "aws:SourceArn" = local.cluster_arn }
      }
    }]
  })

  pod_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
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
          # Any model and inference profile in any region, as the ECS task role
          # without allowlists.
          Resource = [
            "arn:${local.partition}:bedrock:*::foundation-model/*",
            "arn:${local.partition}:bedrock:*:*:inference-profile/*",
            "arn:${local.partition}:bedrock:*:*:application-inference-profile/*",
          ]
        },
        {
          Sid      = "BedrockGuardrails"
          Effect   = "Allow"
          Action   = "bedrock:ApplyGuardrail"
          Resource = "arn:${local.partition}:bedrock:*:${local.account_id}:guardrail/*"
        },
      ],
      var.kms_key_arn != null ? [{
        Sid      = "EncryptLogs"
        Effect   = "Allow"
        Action   = "kms:GenerateDataKey"
        Resource = var.kms_key_arn
      }] : [],
    )
  })
}

resource "aws_iam_role" "pod" {
  name               = "${var.name}-pod-role"
  assume_role_policy = local.assume_role_policy
}

resource "aws_iam_role_policy" "pod" {
  name   = "${var.name}-pod"
  role   = aws_iam_role.pod.id
  policy = local.pod_policy
}

resource "aws_eks_pod_identity_association" "litellm" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.pod.arn

  depends_on = [aws_iam_role_policy.pod]
}
