#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bootstrap-wif.sh [options]

Options (each can also be supplied by the corresponding environment variable):
  --project-id ID             GCP_PROJECT_ID
  --project-number NUMBER     GCP_PROJECT_NUMBER
  --owner OWNER               GITHUB_REPOSITORY_OWNER
  --repository NAME           GITHUB_REPOSITORY_NAME
  --repository-id ID          GITHUB_REPOSITORY_ID
  --owner-id ID               GITHUB_REPOSITORY_OWNER_ID
  --pool-id ID                GCP_WIF_POOL_ID (default: github)
  --provider-id ID            GCP_WIF_PROVIDER_ID (default: github)
  --service-account NAME      GCP_SERVICE_ACCOUNT_NAME (default: github-actions)
  --environment NAME          GITHUB_ENVIRONMENT (default: gcp-poc)
EOF
}

project_id="${GCP_PROJECT_ID:-}"
project_number="${GCP_PROJECT_NUMBER:-}"
repository_owner="${GITHUB_REPOSITORY_OWNER:-}"
repository_name="${GITHUB_REPOSITORY_NAME:-}"
repository_id="${GITHUB_REPOSITORY_ID:-}"
owner_id="${GITHUB_REPOSITORY_OWNER_ID:-}"
pool_id="${GCP_WIF_POOL_ID:-github}"
provider_id="${GCP_WIF_PROVIDER_ID:-github}"
service_account_name="${GCP_SERVICE_ACCOUNT_NAME:-github-actions}"
environment_name="${GITHUB_ENVIRONMENT:-gcp-poc}"

while (($#)); do
  case "$1" in
    --project-id) project_id="$2"; shift 2 ;;
    --project-number) project_number="$2"; shift 2 ;;
    --owner) repository_owner="$2"; shift 2 ;;
    --repository) repository_name="$2"; shift 2 ;;
    --repository-id) repository_id="$2"; shift 2 ;;
    --owner-id) owner_id="$2"; shift 2 ;;
    --pool-id) pool_id="$2"; shift 2 ;;
    --provider-id) provider_id="$2"; shift 2 ;;
    --service-account) service_account_name="$2"; shift 2 ;;
    --environment) environment_name="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

required=(project_id project_number repository_owner repository_name repository_id owner_id)
for variable in "${required[@]}"; do
  if [[ -z "${!variable}" ]]; then
    echo "Missing required value: $variable" >&2
    usage >&2
    exit 2
  fi
done

[[ "$project_number" =~ ^[0-9]+$ ]] || { echo "project-number must be numeric" >&2; exit 2; }
[[ "$repository_id" =~ ^[0-9]+$ ]] || { echo "repository-id must be numeric" >&2; exit 2; }
[[ "$owner_id" =~ ^[0-9]+$ ]] || { echo "owner-id must be numeric" >&2; exit 2; }
[[ "$pool_id" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || { echo "Invalid pool-id" >&2; exit 2; }
[[ "$provider_id" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || { echo "Invalid provider-id" >&2; exit 2; }
[[ "$service_account_name" =~ ^[a-z][a-z0-9-]{5,29}$ ]] || {
  echo "service-account must be 6-30 lowercase letters, digits, or hyphens" >&2
  exit 2
}

command -v gcloud >/dev/null || { echo "gcloud is required" >&2; exit 1; }

echo "Enabling required Google Cloud APIs in ${project_id}..."
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="$project_id"

if ! gcloud iam workload-identity-pools describe "$pool_id" \
  --location=global --project="$project_id" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$pool_id" \
    --location=global \
    --display-name="GitHub Actions" \
    --project="$project_id"
fi

provider_condition="assertion.repository_id == '${repository_id}' && assertion.repository_owner_id == '${owner_id}' && assertion.repository == '${repository_owner}/${repository_name}' && assertion.ref == 'refs/heads/main' && assertion.environment == '${environment_name}'"
mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.repository_owner_id=assertion.repository_owner_id,attribute.environment=assertion.environment"

if gcloud iam workload-identity-pools providers describe "$provider_id" \
  --location=global --workload-identity-pool="$pool_id" \
  --project="$project_id" >/dev/null 2>&1; then
  existing_condition="$(gcloud iam workload-identity-pools providers describe "$provider_id" \
    --location=global --workload-identity-pool="$pool_id" \
    --project="$project_id" --format='value(attributeCondition)')"
  if [[ "$existing_condition" != "$provider_condition" ]]; then
    cat >&2 <<EOF
Refusing to update WIF provider ${provider_id}: its existing trust condition
does not match this repository (${repository_owner}/${repository_name},
repository ID ${repository_id}, owner ID ${owner_id}, refs/heads/main,
environment ${environment_name}). Use a repository-specific --provider-id or
review the existing provider manually.
EOF
    exit 1
  fi
  gcloud iam workload-identity-pools providers update-oidc "$provider_id" \
    --location=global \
    --workload-identity-pool="$pool_id" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$mapping" \
    --attribute-condition="$provider_condition" \
    --project="$project_id"
else
  gcloud iam workload-identity-pools providers create-oidc "$provider_id" \
    --location=global \
    --workload-identity-pool="$pool_id" \
    --display-name="GitHub Actions OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$mapping" \
    --attribute-condition="$provider_condition" \
    --project="$project_id"
fi

service_account="${service_account_name}@${project_id}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$service_account" \
  --project="$project_id" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$service_account_name" \
    --display-name="GitHub Actions (WIF)" \
    --project="$project_id"
fi

principal="principalSet://iam.googleapis.com/projects/${project_number}/locations/global/workloadIdentityPools/${pool_id}/attribute.repository_id/${repository_id}"
gcloud iam service-accounts add-iam-policy-binding "$service_account" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$principal" \
  --project="$project_id" >/dev/null

# Browser is read-only and includes resourcemanager.projects.get, which is all
# the authentication test needs. Do not grant Owner, Editor, or IAM Admin here.
gcloud projects add-iam-policy-binding "$project_id" \
  --member="serviceAccount:${service_account}" \
  --role="roles/browser" \
  --condition=None >/dev/null

provider_resource="projects/${project_number}/locations/global/workloadIdentityPools/${pool_id}/providers/${provider_id}"
cat <<EOF

Bootstrap complete. Configure these GitHub Environment variables in "gcp-poc":
GCP_PROJECT_ID=${project_id}
GCP_WIF_PROVIDER=${provider_resource}
GCP_SERVICE_ACCOUNT=${service_account}

The provider only accepts repository ${repository_owner}/${repository_name}
(repository ID ${repository_id}), owner ID ${owner_id}, refs/heads/main, and
environment ${environment_name}. Environment branch protection remains a
GitHub setting.
EOF
