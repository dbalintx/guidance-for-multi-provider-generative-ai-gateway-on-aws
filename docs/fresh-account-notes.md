# Deploying into a fresh AWS account — prerequisites and gotchas

Working notes collected during Milestone 1 deploy testing in a brand-new, never-bootstrapped account. Folded into the Setup guide in Milestone 2. Record every prerequisite here the moment it is hit, even when a script automates it.

## Known upfront (to be verified on the real account)

- **Terraform state bootstrap.** Terraform has no `cdk bootstrap` equivalent; state needs a versioned, private S3 bucket with locking before the first `terraform init`. `deploy/deploy.sh` creates it on first run — that creation *is* the bootstrap step: bucket `litellm-gateway-tfstate-<account-id>-<region>` (override with `TF_STATE_BUCKET`), versioning on, SSE-S3 encryption, all public access blocked, native S3 state locking (`use_lockfile=true`, Terraform >= 1.10, no DynamoDB table). The caller needs `s3:CreateBucket`, `s3:PutBucketVersioning`, `s3:PutEncryptionConfiguration`, `s3:PutPublicAccessBlock`, `s3:ListBucket`/`HeadBucket`, object read/write on the bucket, and `sts:GetCallerIdentity` (used to derive the bucket name).
- **Bedrock model access.** A fresh account has access to no foundation models. Model access must be requested/enabled (console → Bedrock → Model access) in the target region before any invocation can succeed; some vendors require a use-case form. Without it, the gateway deploys fine and every model call fails.
- **Service-linked roles.** First-ever use of ECS, ElastiCache, RDS, ELB or Client VPN in an account creates service-linked roles implicitly; creation requires `iam:CreateServiceLinkedRole`.
- **Default quotas.** Possible first-deploy blockers: 5 Elastic IPs/region (NAT), VPCs/region (5), ALBs/region, Fargate on-demand vCPU quota.
- **Region enablement.** Opt-in regions must be enabled on the account first.
- **Customer KMS key policy (when `kms_key_arn` is set).** The foundation passes the key ARN to RDS, ElastiCache, Secrets Manager, CloudWatch Logs and S3 but does not manage the key's policy. The key policy must allow those services (and the deploying principal) to use the key — in particular CloudWatch Logs needs `kms:Encrypt*`/`kms:Decrypt*`/`kms:GenerateDataKey*`/`kms:Describe*` granted to `logs.<region>.amazonaws.com`, or the flow-log group creation fails with `AccessDeniedException`; RDS/ElastiCache fail at create time with a KMS error if the key is unusable. With `kms_key_arn = null` everything uses AWS-managed keys and no key policy work is needed.
- **RDS Enhanced Monitoring / Performance Insights.** The foundation creates the monitoring role itself (`<deployment>-rds-monitoring`), but the deploying principal needs `iam:CreateRole`, `iam:AttachRolePolicy` and `iam:PassRole` for it. Performance Insights must be available for the chosen instance class (it is for `db.t3.small`, the default).
- **Availability Zones.** The created VPC takes the first two available AZs. Accounts whose default region has fewer than two usable AZs (rare; some opt-in regions or capacity-restricted AZs) cannot deploy; bring-your-own-VPC validation enforces two AZs as well.
- **ElastiCache auth + TLS from clients.** Redis requires TLS (`transit_encryption_mode = "required"`) and an auth token. Any client beyond the gateway (for example something admitted via `extra_data_ingress_cidrs`) must connect with `rediss://` and the token from the Redis auth secret — plain `redis://` connections are refused at the protocol level, which looks like a timeout from naive clients.

## Discovered during testing

(append entries as `YYYY-MM-DD — <symptom> — <cause> — <fix/prerequisite>`)
