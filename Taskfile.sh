#!/bin/bash
set -e

# Load environment variables for Google Cloud configuration
source config.env

# //////////////////////////////////////////////////////////////////////////////
# START tasks

run-application() {
  uv run litestar --app src.main:app run
}

setup-project() {
  echo "...installing uv..."
  brew install uv
  echo "...setting up project environment..."
  uv sync --frozen --no-cache
}

install() {
  uv add "$1"
}

test() {
  uv run python3 -m pytest test/test_*.py
}

validate() {
  uv run ruff check --fix
}

deploy() {
  echo "... fetching project variables ..."
  NAME="$(uv run python3 -c "import toml; print(toml.load('pyproject.toml')['project']['name'])")"
  VERSION="$(uv run python3 -c "import toml; print(toml.load('pyproject.toml')['project']['version'])")"
  DATETIME=$(uv run date +"%y-%m-%d-%H%M%S")
  IMAGE_TAG="${SERVICE_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/docker/${NAME}:${VERSION}-${DATETIME}"

  echo "... building docker image ..."
  uv run gcloud auth configure-docker "${SERVICE_REGION}-docker.pkg.dev"
  uv run docker build --platform linux/amd64 --tag "${IMAGE_TAG}" .

  echo "... pushing image to artifact registry ..."
  uv run docker push "${IMAGE_TAG}"

  echo "... deploying image to cloud run ..."
  uv run gcloud run deploy "${NAME}" \
    --project "${GCP_PROJECT_ID}" \
    --image "${IMAGE_TAG}" \
    --platform managed \
    --timeout "${SERVICE_TIMEOUT}" \
    --memory "${SERVICE_MEMORY}" \
    --service-account "${CLOUD_RUN_SERVICE_ACCOUNT}" \
    --region "${SERVICE_REGION}"
}

release() {
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [ "$CURRENT_BRANCH" = "main" ]; then
    DATETIME=$(date +"%Y%d%m-%H%M%S")
    git tag -am "release(trigger)-$DATETIME" "release(trigger)-$DATETIME" -f && git push origin --tags -f
  else
    echo "You need to checkout the 'main' branch to run a release."
    echo "Current branch is: $CURRENT_BRANCH"
  fi
}

authenticate() {
  uv run gcloud auth login
}

create-identity-token() {
  uv run gcloud auth print-identity-token
}

setup-gcloud() {
  echo "--- SETTING UP GOOGLE CLOUD INFRASTRUCTURE ---"
  
  # Check if service account exists
  if ! gcloud iam service-accounts list --project="${GCP_PROJECT_ID}" --filter="email:${SA_CLOUD_RUN}@${GCP_PROJECT_ID}.iam.gserviceaccount.com" --format="value(email)" | grep -q "${SA_CLOUD_RUN}"; then
    echo "Creating service account: ${CLOUD_RUN_SERVICE_ACCOUNT}"
    gcloud iam service-accounts create "${SA_CLOUD_RUN}" --project "${GCP_PROJECT_ID}"
    echo "SA_CLOUD_RUN=\"${SA_CLOUD_RUN}\"" >> config.env
  else
    echo "Service account ${CLOUD_RUN_SERVICE_ACCOUNT} already exists"
  fi

  # Check if workload identity pool exists
  if ! gcloud iam workload-identity-pools list --project="${GCP_PROJECT_ID}" --location="global" --format="value(name)" | grep -q "github"; then
    echo "Creating workload-identity-pool in project ${GCP_PROJECT_ID}"
    gcloud iam workload-identity-pools create "github" \
    --project="${GCP_PROJECT_ID}" \
    --location="global" \
    --display-name="GitHub Actions Pool"
  else
    echo "Workload identity pool 'github' already exists"
  fi

  echo "Retrieving workload-identity-pool name in project ${GCP_PROJECT_ID}"
  WIF_POOL_NAME=$(gcloud iam workload-identity-pools describe "github" \
  --project="${GCP_PROJECT_ID}" \
  --location="global" \
  --format="value(name)")
  echo "Workload-identity-pool ${WIF_POOL_NAME} already exists"

  REPO_NAME=$(cat pyproject.toml | grep "^name\s*=" | cut -d'=' -f2 | tr -d ' "' | head -n1)

  # Check if IAM policy binding exists
  if ! gcloud iam service-accounts get-iam-policy "${CLOUD_RUN_SERVICE_ACCOUNT}" \
    --project="${GCP_PROJECT_ID}" \
    --format="json" | jq -e ".bindings[] | select(.role == \"roles/iam.workloadIdentityUser\" and (.members | type == \"array\") and (.members[] | tostring | contains(\"principalSet://iam.googleapis.com/${WIF_POOL_NAME}/attribute.repository/${GITHUB_ORG}/${REPO_NAME}\")))" > /dev/null; then
    echo "Adding iam-policy-binding for ${CLOUD_RUN_SERVICE_ACCOUNT} in project ${GCP_PROJECT_ID}"
    gcloud iam service-accounts add-iam-policy-binding "${CLOUD_RUN_SERVICE_ACCOUNT}" \
      --project="${GCP_PROJECT_ID}" \
      --role="roles/iam.workloadIdentityUser" \
      --member="principalSet://iam.googleapis.com/${WIF_POOL_NAME}/attribute.repository/${GITHUB_ORG}/${REPO_NAME}"
  else
      echo "IAM policy binding already exists for ${CLOUD_RUN_SERVICE_ACCOUNT}"
  fi

  # Check if workload identity provider exists
  if ! gcloud iam workload-identity-pools providers list --project="${GCP_PROJECT_ID}" --location="global" --workload-identity-pool="github" --format="value(name)" | grep -q "${REPO_NAME}"; then
    echo "Creating workload identity provider ${REPO_NAME}"
    gcloud iam workload-identity-pools providers create-oidc "${REPO_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="github" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository_owner == '${GITHUB_ORG}'"
  else
    echo "Workload identity provider ${REPO_NAME} already exists"
  fi

  WIF_PROVIDER_NAME=$(gcloud iam workload-identity-pools providers describe "${REPO_NAME}" \
  --project="${GCP_PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="github" \
  --format="value(name)")

  echo "Workload-identity-provider ${WIF_PROVIDER_NAME} retrieved"
  echo "WIF_PROVIDER=\"${WIF_PROVIDER_NAME}\"" >> config.env
  echo "SUCCESS: SETTING UP GOOGLE CLOUD INFRASTRUCTURE IS COMPLETE"
}

# END tasks
# //////////////////////////////////////////////////////////////////////////////

help() {
  echo "Usage: ./Taskfile.sh [task]"
  echo
  echo "Available tasks:"
  echo "  run                           Run the application locally."
  echo "  setup                         Install uv and set up the project environment."
  echo "  install <package>             Add a package to the project dependencies."
  echo "  test                          Run the tests using pytest."
  echo "  validate                      Perform code linting and formatting using rust."
  echo "  deploy                        Deploy application to Google Cloud Run."
  echo "  authenticate                  Authenticate to Google Cloud."
  echo "  create-identity-token         Create an identity token for external request authentication."
  echo "  setup-gcloud                  Set up the Google Cloud settings for Workload Identity Federation."
  echo
  echo "If no task is provided, the default is to run the application."
}

# Check if the provided argument matches any of the functions
if declare -f "$1" > /dev/null; then
  "$@"  # If the function exists, run it with any additional arguments
else
  echo "Error: Unknown task '$1'"
  echo
  help  # Show help if the task is not recognized
fi

# Run application if no argument is provided
"${@:-run}"
