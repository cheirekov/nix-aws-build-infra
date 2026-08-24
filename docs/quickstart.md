# Quick start for a new deployment

This guide starts with a clean fork and ends with a cache fixture on ephemeral
x86_64 and ARM64 runners. Commands marked **AWS mutation** can create billable
resources. All other discovery and validation steps are local or read-only.

## 1. Fork and inspect

Create a public repository from this template and clone it. Keep the default
name or pass a different name consistently to the initialization command.

```console
git clone https://github.com/OWNER/nix-aws-build-infra.git
cd nix-aws-build-infra
nix develop
gh auth status
./scripts/check.sh
```

Review `infra/`, `packer/`, `.github/workflows/`, and the saved OpenTofu plan
before granting credentials. A public repository exposes only code and public
cache metadata; private keys and deployment state must remain ignored.

## 2. Discover immutable GitHub identities

Create the trusted build repositories before initialization. Authenticate `gh`
with read access to them, then run:

```console
./scripts/init-deployment.sh \
  --github-owner OWNER \
  --infra-repository nix-aws-build-infra \
  --repository TRUSTED_BUILD_REPOSITORY \
  --region eu-central-1 \
  --monthly-budget-usd 25
```

Repeat `--repository` for every trusted caller. The script reads immutable
owner/repository IDs from GitHub, confirms immutable Actions OIDC subjects,
generates separate CI/local signing keys, and writes:

- `.deployment/terraform.tfvars.json` and public signing keys;
- `.secrets/cache-private-key` and `.secrets/cache-local-private-key`.

It does not contact AWS. Both directories are ignored. Never publish their
private-key files. If a repository predates GitHub's immutable OIDC default,
enable immutable subjects in its Actions OIDC settings before rerunning the
initializer.

`deployment.example.tfvars.json` is a schema example only; do not copy its
placeholder IDs into a real trust policy.

## 3. Prepare the infrastructure administrator

Use an organization-managed IAM Identity Center profile with permission to
create the reviewed infrastructure. Do not use a long-lived IAM-user access
key.

```console
aws sso login --profile APPROVED_SSO_INFRA_ADMIN_PROFILE
export NIX_AWS_INFRA_PROFILE=APPROVED_SSO_INFRA_ADMIN_PROFILE
export TF_VAR_budget_notification_email=OPERATOR_EMAIL
aws sts get-caller-identity --profile "$NIX_AWS_INFRA_PROFILE"
```

The email is a private input and is not written to the public deployment
reference. Subscription confirmation is required before SNS can deliver budget
notifications.

## 4. Bootstrap state and review the plan

The first command is an **AWS mutation**: it creates or hardens an encrypted,
versioned S3 state bucket. It writes the concrete backend only to ignored
`infra/backend.hcl`.

```console
./scripts/bootstrap-state.sh
./scripts/deploy.sh plan
tofu -chdir=infra show ../.deployment/infra.tfplan
```

Confirm the account, region, VPC/subnets, IAM trust IDs, budget, cache and
watchdog resources. Confirm no private key appears in the plan. If inputs
change, discard the saved plan and create a new one; never apply an old plan to
a changed configuration.

## 5. Apply the reviewed infrastructure

This is an **AWS mutation** and creates billable resources:

```console
./scripts/deploy.sh apply
```

The command applies exactly `.deployment/infra.tfplan`, uploads the two private
signing keys to their separate Secrets Manager secrets, verifies both secrets,
then removes the local private-key copies and saved plan. It does not build an
AMI and does not create a GitHub App.

Render safe client and public metadata after apply:

```console
./scripts/render-client-config.sh >nix-aws-cache.nix
mkdir -p deployments/DEPLOYMENT_NAME
./scripts/render-public-deployment.sh deployments/DEPLOYMENT_NAME/public.json
```

Review the public JSON before committing it. It must contain only region,
project name, public GitHub IDs, CloudFront URL and Nix public keys.

## 6. Assign the local operator role

Render the least-privilege policy from applied resource ARNs:

```console
./scripts/render-identity-center-policy.sh
```

Give the generated policy to the organization administrator, who creates and
assigns `NixAwsBuildOperator`. Configure the local named profile exactly as
described in [Identity Center](identity-center.md). Infrastructure-admin and
daily operator profiles must be separate.

## 7. Configure GitHub

Follow [GitHub App setup](github-app.md). In every allowlisted caller, create a
protected `aws-build` environment and configure:

- environment/repository variable `NIX_AWS_ROLE_ARN` from
  `tofu -chdir=infra output -raw github_provisioner_role_arn`;
- variable `NIX_AWS_GITHUB_APP_ID`;
- repository secret `NIX_AWS_GITHUB_APP_PRIVATE_KEY`.

In the infrastructure repository also set:

- `NIX_AWS_IMAGE_ROLE_ARN` from
  `tofu -chdir=infra output -raw github_image_builder_role_arn`;
- optional `NIX_AWS_REGION`, `NIX_AWS_PROJECT`, and
  `NIX_AWS_GITHUB_ENVIRONMENT` variables when defaults were changed.

For external caller workflows, pass the matching `aws_region`, `project_name`,
and `github_environment` reusable-workflow inputs when defaults were changed.

Protect the environment to trusted branches. A fork pull request must never be
able to select the privileged environment or receive the App key.

## 8. Build both AMIs

Choose one method. Both are **AWS mutations** and incur temporary EC2/EBS cost:

- manually run the protected `build runner AMI` workflow; or
- run `./scripts/deploy.sh build-amis` with the infrastructure-admin profile.

The resulting AMI IDs are published under:

```text
/PROJECT_NAME/ami/x86_64-linux
/PROJECT_NAME/ami/aarch64-linux
```

The watchdog retains the latest two tagged AMIs/snapshots for each
architecture.

## 9. Prove cache and cleanup behavior

Run `cache fixture smoke test` manually with `standard-x86_64`, then repeat it.
The second fresh runner should substitute from CloudFront. Repeat with
`standard-aarch64` and verify the fixture ELF architecture. In AWS, confirm the
runner instance, Fleet, launch template, EBS volume, temporary SSM parameter
and DynamoDB lease are gone after each job.

Only after the fixture passes should a trusted project add the pinned caller
shown in the main README. Keep full builds manual until their cache-hit repeat
also succeeds.

## 10. Enable local operation

After central assignment:

```console
aws sso login --profile nix-aws-build
nix profile install github:OWNER/nix-aws-build-infra/FULL_COMMIT_SHA
nix-aws cost status
nix-aws build .#package
```

Read-only local builds can use CloudFront without AWS credentials. Explicit
`--push`, `cache push`, one-shot remote builds and sessions require the scoped
SSO profile. See [Local usage](local-usage.md).

## Adding another repository later

Discover its immutable repository ID, add it to `allowed_repositories` in the
ignored tfvars, install the existing GitHub App on that repository, and make a
new reviewed `plan`/`apply`. Then add its protected environment, variables,
secret and pinned caller workflow. Creating a second GitHub App is unnecessary.
