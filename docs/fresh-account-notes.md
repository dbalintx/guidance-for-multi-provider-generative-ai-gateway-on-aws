# Deploying into a fresh AWS account — prerequisites and gotchas

Working notes collected during Milestone 1 deploy testing in a brand-new, never-bootstrapped account. Folded into the Setup guide in Milestone 2. Record every prerequisite here the moment it is hit, even when a script automates it.

## Known upfront (to be verified on the real account)

- **Terraform state bootstrap.** Terraform has no `cdk bootstrap` equivalent; state needs a versioned, private S3 bucket with locking before the first `terraform init`. `deploy/deploy.sh` creates it on first run — that creation *is* the bootstrap step: bucket `litellm-gateway-tfstate-<account-id>-<region>` (override with `TF_STATE_BUCKET`), versioning on, SSE-S3 encryption, all public access blocked, native S3 state locking (`use_lockfile=true`, Terraform >= 1.10, no DynamoDB table). The caller needs `s3:CreateBucket`, `s3:PutBucketVersioning`, `s3:PutEncryptionConfiguration`, `s3:PutPublicAccessBlock`, `s3:ListBucket`/`HeadBucket`, object read/write on the bucket, and `sts:GetCallerIdentity` (used to derive the bucket name).
- **Bedrock model access.** A fresh account has access to no foundation models. Model access must be requested/enabled (console → Bedrock → Model access) in the target region before any invocation can succeed; some vendors require a use-case form. Without it, the gateway deploys fine and every model call fails.
- **Service-linked roles.** First-ever use of ECS, ElastiCache, RDS, ELB or Client VPN in an account creates service-linked roles implicitly; creation requires `iam:CreateServiceLinkedRole`.
- **Default quotas.** Possible first-deploy blockers: 5 Elastic IPs/region (NAT), VPCs/region (5), ALBs/region, Fargate on-demand vCPU quota.
- **Region enablement.** Opt-in regions must be enabled on the account first.

## Discovered during testing

(append entries as `YYYY-MM-DD — <symptom> — <cause> — <fix/prerequisite>`)
