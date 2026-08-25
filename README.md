# nix-aws-build-infra

Reusable infrastructure for signed Nix binary caches and ephemeral native
`x86_64-linux`/`aarch64-linux` builders on AWS EC2 Spot. It supports trusted
GitHub Actions repositories and explicit local remote builds without inbound
network ports or long-lived AWS access keys.

The repository is a tenant-neutral template. Owner IDs, repository IDs,
signing keys, AWS state, email addresses and account identifiers are generated
or discovered into ignored deployment files. The `deployments/` directory
contains optional, public, read-only references; generic code does not default
to any reference deployment.

## What it provides

- private S3 binary-cache origin with public read-only CloudFront access;
- separate CI and local-publisher Nix signing identities;
- one-job ephemeral GitHub runners registered through a GitHub App;
- GitHub OIDC and AWS IAM Identity Center instead of permanent AWS keys;
- `standard` 16-vCPU and `large` 32-vCPU Spot profiles;
- native x86_64 and ARM64 Packer images;
- local `nix-aws build`, reusable sessions, cache publishing, logs and cost
  estimates;
- DynamoDB concurrency lease, unconditional cleanup and a 12-hour watchdog;
- OpenTofu budget alarms, cache-size alarm and AMI/snapshot retention.

Local builds are the default and create no EC2 resources. Remote instances
exist only for `--remote`, `session start`, or a trusted workflow invocation.
There is no automatic On-Demand fallback.

## Start here

The complete fresh-fork procedure is in [Quick start](docs/quickstart.md). The
safe sequence is deliberately split into reviewable phases:

```console
nix develop
./scripts/init-deployment.sh --github-owner OWNER \
  --infra-repository nix-aws-build-infra \
  --repository TRUSTED_BUILD_REPOSITORY

export NIX_AWS_INFRA_PROFILE=APPROVED_SSO_INFRA_ADMIN_PROFILE
./scripts/bootstrap-state.sh
./scripts/deploy.sh plan
tofu -chdir=infra show ../.deployment/infra.tfplan
./scripts/deploy.sh apply
```

`init-deployment.sh` only performs GitHub read-only discovery and writes
ignored local files. `bootstrap-state.sh`, `apply`, and AMI builds are explicit
AWS mutations. `apply` accepts only the saved plan; it never uses
`-auto-approve`. AMI construction is a separate `deploy.sh build-amis` step or
the protected `build runner AMI` workflow.

Do not commit `.deployment/`, `.secrets/`, `infra/backend.hcl`, plans, Packer
manifests, or Terraform state. They are ignored by this repository.

## GitHub Actions

Create and install the least-privilege GitHub App as described in
[GitHub App setup](docs/github-app.md). A trusted caller pins this repository to
an audited commit, not a movable branch:

```yaml
jobs:
  build:
    permissions:
      contents: read
      id-token: write
    uses: OWNER/nix-aws-build-infra/.github/workflows/nix-build.yml@FULL_COMMIT_SHA
    with:
      flake_attribute: package
      runner_profile: standard-x86_64
      # Also pass aws_region, project_name, and github_environment when the
      # deployment does not use their documented defaults.
    secrets:
      github_app_private_key: ${{ secrets.NIX_AWS_GITHUB_APP_PRIVATE_KEY }}
```

The reusable workflow checks out its own helper scripts using GitHub's
`job.workflow_repository` and `job.workflow_sha` contexts. It does not assume a
particular owner or branch. Only allowlisted immutable owner/repository IDs and
the protected environment can assume the AWS role. Do not invoke this
privileged workflow for untrusted pull-request code.

## Local use

Install from your own pinned fork or use its development shell:

```console
nix profile install github:OWNER/nix-aws-build-infra/FULL_COMMIT_SHA
nix-aws build .#package
nix-aws build --push .#package
nix-aws cache push ./result
nix-aws build --remote --system aarch64-linux --profile standard .#package
```

`build --push` starts from only the outputs built by that invocation, then lets
Nix add the dependency closure required for a valid project cache. Existing
cache paths are skipped. `cache push ./result` applies the same rule to an
existing result; neither command mirrors unrelated local store paths.

Configure the public cache by rendering the generated client fragment after
deployment:

```console
./scripts/render-client-config.sh >nix-aws-cache.nix
```

Local publication and remote builders require the scoped
`nix-aws-build` Identity Center profile. Read-only CloudFront substitution does
not require an AWS account. See [Local usage](docs/local-usage.md) and
[Identity Center](docs/identity-center.md).

## Architecture and safety boundaries

The GitHub-hosted provision job exchanges OIDC for a scoped AWS role and uses
a short-lived GitHub App token. EC2 Fleet selects Spot capacity across instance
families and availability zones. A one-time encrypted SSM parameter carries
runner registration data. The instance has IMDSv2, an instance role, SSM, no
inbound security-group rules, and delete-on-termination encrypted gp3 storage.

Completed Nix outputs are signed and uploaded as they become available. S3
remains private; CloudFront OAC receives only `GET`/`HEAD`. The local operator
cannot retrieve the CI signing key, delete cache objects, or administer IAM.
The GitHub runner and local remote-builder roles have separate signing secrets.

Cleanup removes the fleet, instance, launch template and one-time parameter even
when a build fails, then releases the versioned lease only after owner-tagged
EC2 resources are inactive. `SIGINT`/`SIGTERM`, expired/orphaned recovery and
operator inspection use the same conditional lease checks. EventBridge/Lambda
cleans tagged orphaned resources older than 12 hours and never deletes an
expired lease while its builder resources remain active. CloudWatch logs are
retained for 14 days and local CLI logs for 30 days. See the recovery procedure
in [Local usage](docs/local-usage.md#interrupted-build-and-lease-recovery).

## Cost controls

Defaults are Frankfurt (`eu-central-1`), one concurrent builder, a USD 25
monthly soft budget, public subnets without NAT Gateway, CloudFront
`PriceClass_100`, and retention of the newest two AMIs per architecture. The
CLI estimates current Spot, EBS and public IPv4 costs before a local remote
session. AWS Budget notifications are delayed alerts, not a real-time hard
cap. Identity Center itself has no additional service fee, but its organization
administrator must assign the operator permission set.

## Reproducibility and validation

The Nix input, provider locks, tool versions, Nix installer version, GitHub
runner version and runner archive hashes are pinned or lockable. AMIs are
operationally reproducible, not byte-for-byte reproducible: they deliberately
start from the current official Ubuntu 24.04 image and receive current security
packages and AWS agents. See [Reproducibility](docs/reproducibility.md).

Run all non-mutating checks with:

```console
nix develop --command ./scripts/check.sh
```

The suite validates OpenTofu and Packer, checks Actions and shell code, runs
Python unit tests, verifies least-privilege assertions, and rejects known
tenant-specific values from generic files. No check creates AWS resources.

Deployment remains separate from build/cache operation. A `deploy-rs` pilot
pattern is documented in [Deployment](docs/deployment.md); this project is not
a FlakeHub replacement.
