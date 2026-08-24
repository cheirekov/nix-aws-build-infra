# IAM Identity Center rollout

The AWS account is an organization member, so the organization administrator
must create and assign the permission set. An account-local Identity Center
instance cannot provide AWS account permission sets.

1. Apply the OpenTofu changes with an approved infrastructure administrator.
2. Render the resource-specific inline policy into the ignored deployment
   directory:

   ```console
   ./scripts/render-identity-center-policy.sh
   ```

3. In the organization management account create `NixAwsBuildOperator`, attach
   the rendered inline policy, set a maximum session duration of 12 hours, and
   assign it to the approved user for the build account.
4. Activate the `Project` cost-allocation tag in the billing account.
5. Configure the workstation without access keys:

   ```ini
   [sso-session nix-aws]
   sso_start_url = https://ORGANIZATION.awsapps.com/start
   sso_region = IDENTITY_CENTER_REGION
   sso_registration_scopes = sso:account:access

   [profile nix-aws-build]
   sso_session = nix-aws
   sso_account_id = BUILD_ACCOUNT_ID
   sso_role_name = NixAwsBuildOperator
   region = DEPLOYMENT_REGION
   output = json
   ```

6. Run `aws sso login --profile nix-aws-build` and verify that
   `aws sts get-caller-identity --profile nix-aws-build` returns an assumed
   `AWSReservedSSO_NixAwsBuildOperator_*` role.

`nix-aws` intentionally rejects IAM-user and default-profile credentials for
cache publication and remote builders. Infrastructure deployment uses a
separate, centrally approved profile passed as `NIX_AWS_INFRA_PROFILE`; the
operator permission set cannot modify OpenTofu infrastructure or IAM.

When a deployment uses a different project, region or profile name, set
`NIX_AWS_PROJECT`, `NIX_AWS_REGION`, and `NIX_AWS_PROFILE` for the CLI. The
default operator role name is `NixAwsBuildOperator`; deployments using another
role name must set a tightly scoped `NIX_AWS_OPERATOR_ROLE_PATTERN`.

The permission set can pass only the dedicated local-builder instance role.
That role reads `nix-aws-local-1`; only the GitHub runner role can read the CI
signing secret. Both roles are denied S3 object deletion.
