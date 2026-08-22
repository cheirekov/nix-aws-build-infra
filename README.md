# nix-aws-build-infra

Reusable infrastructure for one-job GitHub Actions runners on EC2 Spot and a
signed Nix binary cache backed by private S3 and public read-only CloudFront.
The default deployment targets `eu-central-1`, accepts one trusted build at a
time, and leaves no runner instance or EBS volume behind after a job.

## Architecture

1. A GitHub-hosted provisioning job assumes a narrowly scoped AWS role through
   GitHub OIDC and requests a short-lived runner registration token through a
   GitHub App.
2. EC2 Fleet selects one 32-vCPU Spot instance from the configured types and
   availability zones. The runner has no inbound security-group rules.
3. The AMI fetches its one-time configuration from encrypted SSM Parameter
   Store, exposes the pinned Nix installation to non-login Actions shells,
   registers as an ephemeral runner, and executes exactly one job.
4. Nix reads from CloudFront and uploads signed completed outputs directly to
   the private S3 cache. This preserves useful work if Spot is interrupted.
5. An unconditional cleanup job removes the fleet, instance, launch template,
   SSM parameter and stale runner entry. A 12-hour AWS watchdog is the fallback.

## Bootstrap and deploy

Prerequisites are provided by the Nix development shell:

```console
nix develop
aws sts get-caller-identity
./scripts/bootstrap-state.sh
./scripts/generate-signing-key.sh
./scripts/deploy.sh
```

`deploy.sh` applies OpenTofu, uploads the private signing key to Secrets
Manager, builds the Packer AMI and publishes its ID to SSM. It does not create
the GitHub App or GitHub repository secrets.

Create a GitHub App owned by `cheirekov`, install it only on approved build
repositories, and grant repository **Administration: read and write** plus
**Metadata: read**. In each caller repository configure:

- environment `aws-build`, restricted to the `main` branch;
- variable `NIX_AWS_ROLE_ARN` from `tofu output github_provisioner_role_arn`;
- variable `NIX_AWS_GITHUB_APP_ID`;
- repository Actions secret `NIX_AWS_GITHUB_APP_PRIVATE_KEY`.

In this infrastructure repository, also set `NIX_AWS_IMAGE_ROLE_ARN` from
`tofu output github_image_builder_role_arn`. Disable GitHub App webhooks; no
callback URL is required. Generate and download one App private key, store it
only as the repository secret above, then delete the downloaded copy.

The OpenTofu defaults bind AWS OIDC trust to the immutable GitHub owner and
repository IDs as well as the protected `aws-build` environment. Update
`github_owner_id` and the `allowed_repositories` name-to-ID map if the owner or
allowlist changes; repository names alone do not match the default OIDC subject
used by newly created repositories.

The signing private key is generated under ignored `.secrets/`, uploaded to
AWS, and deleted locally after a successful deployment. It is never placed in
Git, the AMI, GitHub secrets, or OpenTofu state. Its corresponding public key
is committed as `config/cache-public-key.txt` so clients can configure trust
without querying AWS.

## Calling the reusable workflow

```yaml
jobs:
  build:
    uses: cheirekov/nix-aws-build-infra/.github/workflows/nix-build.yml@main
    permissions:
      contents: read
      id-token: write
    with:
      flake_attribute: br
      verification_script: ./scripts/verify.sh ./result
    secrets:
      github_app_private_key: ${{ secrets.NIX_AWS_GITHUB_APP_PRIVATE_KEY }}
```

The reusable workflow resolves `NIX_AWS_ROLE_ARN` and
`NIX_AWS_GITHUB_APP_ID` from the caller repository's protected `aws-build`
environment. GitHub does not expose environment secrets across
`workflow_call`, so the narrowly scoped App key is a repository secret passed
explicitly through the declared `github_app_private_key` interface. Fork pull
requests cannot access repository Actions secrets.

Do not invoke the workflow for untrusted pull-request code. The runner's
instance role can write to the cache and read its signing key by design.

## Local cache use

After deployment, render the concrete NixOS/Home Manager example:

```console
./scripts/render-client-config.sh
```

The output contains the CloudFront substituter and public signing key. The S3
bucket remains private and blocks all public ACLs and policies; only the
CloudFront distribution can read cache objects.

## Validation

```console
./scripts/check.sh
cd infra && tofu plan -var "cache_public_key=$(cat ../config/cache-public-key.txt)"
```

The included fixture is intentionally small. Run it through the reusable
workflow twice: the second fresh runner should substitute it from CloudFront.
CloudWatch retains runner logs for 14 days. Cache objects have no automatic
expiry because deleting NARs independently of their `.narinfo` files would
create a corrupt cache.

The rollout is deliberately gated:

1. Push this repository and configure the GitHub App, environment and
   variables.
2. Run **cache fixture smoke test** twice and confirm the second run reports a
   cache substitution.
3. Run Brave's **full Brave build** workflow manually and repeat it once for a
   cache-hit test.
4. Only then add the trusted `push`-to-`main` trigger to the Brave caller.

Fork pull requests run only the unprivileged static checks. They do not invoke
the reusable build workflow, and the AWS OIDC trust accepts only the protected
`aws-build` environment in the two allowlisted repositories.
