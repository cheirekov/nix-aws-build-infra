# GitHub App setup

The App exists only to mint short-lived repository runner-registration tokens.
AWS authentication is independent and uses GitHub OIDC. No OAuth user flow,
callback URL, webhook, or OAuth client secret is used by this project.

## Create the App

Under the GitHub user or organization that owns the trusted repositories:

1. Open **Settings → Developer settings → GitHub Apps → New GitHub App**.
2. Choose a unique name and any valid homepage URL.
3. Disable webhooks.
4. Leave callback/setup URLs empty and OAuth-device flow disabled.
5. Set repository permissions to:
   - **Administration: Read and write**;
   - **Metadata: Read-only** (automatic).
6. Select **Only on this account** for installation scope, when available.
7. Create the App and record its numeric App ID.

GitHub may require every App to retain at least one OAuth client secret. This
workflow never reads it. Do not revoke all user tokens and do not put the OAuth
client secret in AWS, Actions, configuration, logs, or this repository. It can
remain unused.

## Install it on trusted repositories

Open the App's **Install App** page, choose the owner, select **Only select
repositories**, and include the infrastructure repository plus each allowlisted
build repository. To add another repository later, return to the App
installation settings and extend the selected repository list; do not create a
new App.

An App listed under Developer settings is the App definition. Installation is
a separate step. If **Configure** is not visible from Developer settings, use
the App's **Install App** item or the account's **Settings → Applications →
Installed GitHub Apps** page.

## Store the private key

Generate one App private key, download it once, and place its complete PEM
contents in the repository Actions secret:

```text
NIX_AWS_GITHUB_APP_PRIVATE_KEY
```

Set it in every trusted caller repository that invokes the reusable workflow.
After verifying the secret, securely remove the downloaded PEM. The key is not
the OAuth client secret and must never be committed or copied into an AMI.

Set the numeric App ID as a non-secret Actions variable:

```text
NIX_AWS_GITHUB_APP_ID
```

The workflow requests an installation token only for the current caller
repository. The token expires automatically.

## Protected environment and AWS role

Create the environment named by `github_environment` (default `aws-build`) in
every allowlisted repository. Restrict it to trusted branches and set:

```text
NIX_AWS_ROLE_ARN
```

OpenTofu binds the role trust to the GitHub OIDC audience, immutable owner ID,
immutable repository ID and environment. A matching name alone is
insufficient. Repository transfers or allowlist changes require a new reviewed
OpenTofu plan.

The infrastructure repository's AMI workflow additionally requires:

```text
NIX_AWS_IMAGE_ROLE_ARN
```

Do not make the privileged workflow reachable from fork pull-request code.

## Key rotation

GitHub permits overlapping App private keys. Generate a new private key, update
all `NIX_AWS_GITHUB_APP_PRIVATE_KEY` secrets, run the fixture once, then delete
the old App private key. OAuth client secrets are unrelated and need not be
rotated for this runner workflow.
