# Google Cloud Template Repository

## 1. Overview

This public repository is a reusable template for Google Cloud applications and
proofs of concept. It supports two separate authentication paths:

- Local development uses an interactive `gcloud` login and Application Default
  Credentials (ADC).
- GitHub Actions uses GitHub's OIDC token with Google Cloud Workload Identity
  Federation (WIF). No service account key is created or stored.

The included workflow only verifies access to the configured project. It does
not change IAM or deploy a Google Cloud service.

## 2. Prerequisites

- A Google Cloud project and a human administrator with permission to create
  WIF pools/providers, service accounts, and IAM bindings.
- `gcloud` installed and the administrator logged in.
- Repository and owner IDs from GitHub. The repository ID is stable for a
  repository and prevents a same-named repository from being trusted.
- Permission to create and configure the `gcp-poc` GitHub Environment.

## 3. Local Development Authentication

Install the Google Cloud CLI, initialize it, and log in interactively:

```bash
curl -sSL https://sdk.cloud.google.com | bash
exec -l "$SHELL"
gcloud init
gcloud auth login
gcloud config set project PROJECT_ID
gcloud auth application-default login
export PROJECT_ID="$(gcloud config list --format='value(core.project)')"
```

These credentials are for local development only. GitHub Actions must not run
`gcloud auth login` or `gcloud auth application-default login`.

## 4. GitHub Actions Authentication

`.github/workflows/gcp-auth-test.yml` uses the official
`google-github-actions/auth` and `google-github-actions/setup-gcloud` actions.
The workflow requests `id-token: write` only on its authentication job, then
exchanges the ephemeral GitHub OIDC token for short-lived credentials while
impersonating the configured service account.

The actions are pinned to full commit SHAs (with their reviewed release tags in
comments). Update the SHA and comment together after reviewing a new release.

## 5. Google Cloud WIF Bootstrap

Run the bootstrap locally as a Google Cloud administrator. It is intentionally
not callable from GitHub Actions:

```bash
chmod +x scripts/bootstrap-wif.sh
scripts/bootstrap-wif.sh \
  --project-id PROJECT_ID \
  --project-number PROJECT_NUMBER \
  --owner OWNER \
  --repository REPOSITORY \
  --repository-id REPOSITORY_ID \
  --owner-id OWNER_ID \
  --pool-id github \
  --provider-id github \
  --service-account github-actions \
  --environment gcp-poc
```

The script also accepts the corresponding environment variables; run
`scripts/bootstrap-wif.sh --help` for their names. It enables the required
APIs, creates or updates the pool and OIDC provider, creates the service
account if necessary, and adds the WIF impersonation binding. Existing
resources are reused rather than deleted. Existing providers are updated only
when their trust condition exactly matches this repository; otherwise the
script stops safely. Use a repository-specific `--provider-id` rather than
overwriting a provider configured for another repository. The provider
condition requires the exact repository ID, owner ID, repository name, and
GitHub Environment.

The service account receives only `roles/browser`, a read-only role sufficient
for the project description test. The bootstrap administrator, not GitHub
Actions, manages WIF and IAM. The provider condition is fixed to
`refs/heads/main` and the selected Environment; change the workflow and
bootstrap deliberately if a template copy uses a different protected branch.

## 6. GitHub Repository Configuration

Create a GitHub Environment named `gcp-poc`. Add these **Environment
variables** (not secrets) using the values printed by the bootstrap:

| Variable | Example shape |
| --- | --- |
| `GCP_PROJECT_ID` | `my-project-123` |
| `GCP_WIF_PROVIDER` | `projects/123/locations/global/workloadIdentityPools/github/providers/github` |
| `GCP_SERVICE_ACCOUNT` | `github-actions@my-project-123.iam.gserviceaccount.com` |

Environment variables are used so a template copy can configure a different
project and repository without source changes. Do not commit real values,
tokens, credential files, or service account keys.

In **Environment settings > Deployment branches and tags**, restrict access to
the `main` branch (or an explicitly reviewed protected rule). Add
**Required reviewers** when human approval is needed before a job can access
Google Cloud. The workflow's `environment: gcp-poc` must remain aligned with
the provider's `assertion.environment` condition.

The WIF condition also requires `refs/heads/main`. Consequently, a workflow
run started from a working branch is expected to be rejected by Google Cloud;
perform the connection check from the protected `main` branch. Pull request
merge refs and fork refs are rejected as well.

## 7. Authentication Test

After configuring the variables, open the Actions tab, select **Google Cloud
authentication test**, and choose **Run workflow**. It prints only the project
ID, authenticated service account email, and non-sensitive project metadata,
then runs:

```bash
gcloud projects describe "$GCP_PROJECT_ID"
```

On failure, the final step prints gcloud version, active project, and active
account diagnostics. It never prints OIDC or access tokens.

## 8. IAM / RBAC

- **Bootstrap administrator:** manages WIF, service accounts, and IAM bindings.
- **GitHub Actions service account:** read-only access to this project, limited
  to the repository and Environment condition above.
- **Future Copilot Cloud Agent:** may propose service-specific roles for a PoC,
  but must not receive Owner, Editor, or Project IAM Admin.

For a future PoC, have an administrator add only the service role required by
that PoC (for example, a narrowly scoped storage or Pub/Sub role), document
the reason, and remove it when the PoC ends. Keep project-wide IAM
administration outside GitHub Actions.

## 9. Security Considerations

- WIF and short-lived credentials replace long-lived JSON keys.
- The provider has an explicit condition for repository ID, owner ID,
  repository name, `refs/heads/main`, and `gcp-poc`; it does not trust
  arbitrary repositories.
- Environment branch restrictions and required reviewers provide the GitHub
  control over which refs can request the credential. The workflow is
  `workflow_dispatch` only, so forks and pull requests do not trigger it.
- A fork has a different repository and owner ID and therefore cannot satisfy
  the provider condition. Pull request refs are not `refs/heads/main`; they
  cannot satisfy it either. This workflow does not use `pull_request_target`.
- `id-token: write` is limited to the one job that needs it.
- Generated ADC, credential artifacts, Terraform state, plans, and local
  configuration are ignored by `.gitignore`.
- Keep the WIF service account in the intended PoC project and do not grant
  permissions in other projects.
- This public template contains no project-specific IDs, keys, tokens, or
  credentials. Run bootstrap against your own Google Cloud project and never
  copy the template author's project or service account variables.

## 10. Troubleshooting

1. Confirm all three Environment variables are present and spelled exactly.
2. Confirm the workflow uses the `gcp-poc` Environment and that its branch
   protection permits the branch being tested.
3. Compare the provider's repository ID, owner ID, repository name, and
   `refs/heads/main` and environment conditions with the current repository.
4. Confirm the service account has `roles/iam.workloadIdentityUser` for the
   repository's `principalSet` and `roles/browser` on the target project.
5. Inspect the workflow's safe diagnostics. Never add token or credential
   output while debugging.
6. Re-run the bootstrap with the same values to reconcile provider mappings
   and conditions; it does not delete resources.

## 11. Future Agentic Workflows Integration

Future Copilot Cloud Agent or Agentic Workflow jobs can reuse the same WIF
provider and Environment pattern. Give each PoC a dedicated service account
or narrowly scoped role where practical. This repository intentionally does
not include autonomous deployment or IAM-changing workflows.

## Public Repository Checklist

Before publishing a template copy, inspect the complete Git history and working
tree for keys, access tokens, credential files, Terraform state, and local
configuration. Configure secret scanning and push protection on the repository.
Never add a credential to an issue, workflow log, README example, or commit;
rotate it immediately if one is exposed. Every copy must bootstrap WIF in its
own Google Cloud project using its own repository and owner IDs.
