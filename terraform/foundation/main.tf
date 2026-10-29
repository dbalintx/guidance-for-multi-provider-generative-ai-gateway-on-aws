# Solutions Library deployment tracking. The stack creates nothing and costs
# nothing; its only job is to carry the guidance's solution ID (SO9022) in its
# description, which is how the AWS Solutions Library counts deployments.
# Drop it if the accelerator is distributed outside the Solutions Library.
resource "aws_cloudformation_stack" "guidance_deployment_metrics" {
  name = "${var.deployment_name}-tracking-stack"
  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Guidance for Running Generative AI Gateway Proxy on AWS. The Solution ID is SO9022 and the Solution Version is 2.0.0"
    Resources = {
      EmptyResource = {
        Type = "AWS::CloudFormation::WaitConditionHandle"
      }
    }
  })
}

# Child modules land on dedicated Milestone 1 branches:
#   vpc-validation (create-or-bring VPC), RDS PostgreSQL Multi-AZ,
#   ElastiCache Redis, S3 config bucket, Secrets Manager secrets,
#   optional customer KMS key, optional demo Client VPN.
