# Moving from version 1 to version 2

Version 2 of this Guidance is a rewrite. It runs the stock LiteLLM proxy without the version 1 middleware, uses
different Terraform root modules and state, and creates its own database. There is no in-place upgrade: deploy
version 2 next to version 1, move your clients over, then destroy the version 1 deployment.

This page is guidance. Test the steps on a copy of your data, and keep version 1 running until version 2 works for
your clients.

## What changed

| Version 1 | Version 2 |
| --- | --- |
| Custom middleware in the request path | Removed. Clients call LiteLLM directly through its OpenAI-compatible API. |
| Server-side chat history (middleware) | Not available. Keep conversation history in your application. |
| Amazon Bedrock prompt ARNs as model IDs | Not available. Register models in LiteLLM (UI or API) and call them by name. |
| Amazon Bedrock-native interface (middleware) | Not available as such. LiteLLM's Amazon Bedrock pass-through routes may cover some clients; check yours. |
| Okta JWT authentication (middleware) | LiteLLM virtual keys, or LiteLLM JWT authentication with any OIDC identity provider (needs a LiteLLM Enterprise licence); see [JWT authentication for applications](deployment.md#jwt-authentication-for-applications). |
| Amazon CloudFront in front of the load balancer | Removed. Public mode uses an internet-facing load balancer with AWS WAF. |
| Amazon EKS deployment | Guidance only, not tested: [examples/eks](../examples/eks/README.md). |
| AWS Service Catalog AppRegistry application | Removed. |
| Per-Region configuration files and deployment scripts | One `deploy/terraform.tfvars` per deployment and `deploy/deploy.sh`; see [deployment.md](deployment.md). |
| LiteLLM 1.82 | LiteLLM 1.106 (pinned by digest in `terraform/app/container.tf`). |

Before you start, list what your version 1 deployment holds: the models and their provider credentials, the
teams, users, virtual keys and budgets, any custom LiteLLM configuration, your identity provider setup, and the
clients that call the gateway.

## Option A: start fresh

The simplest path. Nothing is carried over from version 1.

1. Deploy version 2 ([deployment.md](deployment.md)).
2. Recreate models, teams, users, budgets and virtual keys in the UI or through the LiteLLM API, and give the new
   keys to your clients.
3. Move the clients to the version 2 URL and check them.
4. Destroy the version 1 deployment. Spend history stays in version 1's database: export what you need first.

## Option B: keep the LiteLLM data

Carries version 1's LiteLLM database into version 2: teams, users, virtual keys, budgets, spend, and the models
added through the UI or the API (version 1 set `STORE_MODEL_IN_DB`) with their stored provider credentials.
LiteLLM encrypts those stored credentials with its salt key, so version 2 must use version 1's salt key. Reusing
the master key as well keeps existing administrative automation working.

Not carried over: the models defined in version 1's configuration file (`model_list` in `config/config.yaml`,
built from `config/default-config-base.yaml` and `config/default-config-<region>.yaml`), and the provider API keys
version 1 passed as environment variables (`OPENAI_API_KEY` and the others in its `.env` file). Step 5 registers
them again.

1. **Copy the keys into two plain-string secrets.** Version 1 stores both keys in one JSON secret (name prefix
   `LiteLLMMasterSalt-`); version 2 expects one plain `sk-...` value per secret. The values go from one secret to
   the other without appearing on screen. Set `KMS_KEY_ARN` to the deployment's `kms_key_arn` if it has one;
   leave it empty for the AWS managed key:

   ```bash
   V1_SECRET=<ARN of the version 1 LiteLLMMasterSalt- secret>
   KMS_KEY_ARN=   # the deployment's kms_key_arn, or empty for the AWS managed key
   for k in LITELLM_SALT_KEY LITELLM_MASTER_KEY; do
     aws secretsmanager get-secret-value --secret-id "$V1_SECRET" --query SecretString --output text |
       jq -j --arg k "$k" '.[$k]' |
       aws secretsmanager create-secret --name "llmgw-v1-$(echo "$k" | tr 'A-Z_' 'a-z-')" \
         ${KMS_KEY_ARN:+--kms-key-id "$KMS_KEY_ARN"} \
         --secret-string file:///dev/stdin --query ARN --output text
   done
   ```

   The task execution role can decrypt only the AWS managed key and the deployment's `kms_key_arn`
   ([Customer managed KMS key](deployment.md#customer-managed-kms-key-optional)); a secret encrypted with any
   other key fails at task start.
2. **Point version 2 at them** in `deploy/terraform.tfvars`:

   ```hcl
   existing_salt_key_secret_arn   = "<ARN printed for llmgw-v1-litellm-salt-key>"
   existing_master_key_secret_arn = "<ARN printed for llmgw-v1-litellm-master-key>"
   ```

3. **Create the version 2 database, but not the app yet.** Run `deploy/deploy.sh`, apply the foundation plan and
   answer anything but `yes` at the app plan. The database then exists and is empty.
4. **Copy the database.** Stop changes in version 1 (a maintenance window), then dump its LiteLLM database and
   restore it into version 2's, for example with `pg_dump --format=custom` and
   `pg_restore --no-owner --dbname=<version 2 database URL>`. Both use the database `litellm` and the user
   `llmproxy`. Version 2's connection URL is in the secret of the `database_url_secret_arn` foundation output.
   Both databases are in private subnets: run the commands from a machine or temporary task that can reach them,
   and copy the dump between the two networks if no single machine reaches both. Use a `pg_dump` at least as new
   as the version 1 database server.
5. **Register the configuration-file models.** Existing virtual keys refer to models by name, so register every
   model your clients use from version 1's `config/config.yaml` under the **same `model_name`**:
   - Store each provider API key from version 1's `.env` in Secrets Manager (encrypted as in step 1) and map it in
     `provider_secret_arns`, for example `OPENAI_API_KEY = "<secret ARN>"`.
   - Copy the `model_list` entries you need into the `config_override_file`
     ([configuration.md](configuration.md)), referencing the keys as `api_key: os.environ/OPENAI_API_KEY`. Only
     `model_list` is needed; leave version 1's `general_settings`, `litellm_settings` and `environment_variables`
     out, because version 2 renders its own (an `environment_variables` key would replace the base map and drop
     `STORE_MODEL_IN_DB`).
   - Or add the models in the UI or through the LiteLLM API after step 6, under the same names.

   Amazon Bedrock models need no key: the task role calls Bedrock. Check that each Bedrock model ID is still
   available in your Region; prefer inference profiles where the old ID has been replaced.
6. **Deploy the app.** Run `deploy/deploy.sh` again and apply both plans. The migration task brings the restored
   schema forward before the service starts.
7. **Check it.** Run the [smoke test](deployment.md#smoke-test), call a model from step 5 and a UI-added model
   with an existing version 1 virtual key, and look at teams, keys and spend in the UI.
8. **Move the clients** to the version 2 URL. Changes made in version 1 after the dump are not carried over.
9. **Destroy the version 1 deployment** once version 2 serves your clients.

Server-side chat history from the version 1 middleware is not part of the LiteLLM database and is not carried
over.
