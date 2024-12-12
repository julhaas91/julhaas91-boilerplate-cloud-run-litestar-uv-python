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

  # Check and create SERVICE SA ACCOUNT only if it doesn't exist
  if ! gcloud iam service-accounts list \
    --project="${GCP_PROJECT_ID}" \
    --filter="email:${SA_CLOUD_RUN}@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
    --format="value(email)" | grep -q "${SA_CLOUD_RUN}"; then
    echo "Creating service account: ${SA_CLOUD_RUN}"
    gcloud iam service-accounts create "${SA_CLOUD_RUN}" \
      --project "${GCP_PROJECT_ID}" \
      --quiet
    echo "SA_CLOUD_RUN=\"${SA_CLOUD_RUN}\"" >> config.env
  else
    echo "Service account ${SA_CLOUD_RUN} already exists"
  fi

  # Check and create GITHUB AUTOMATION SA ACCOUNT only if it doesn't exist
  if ! gcloud iam service-accounts list \
    --project="${GCP_PROJECT_ID}" \
    --filter="email:github-automation@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
    --format="value(email)" | grep -q "github-automation"; then
    echo "Creating service account: github-automation"
    gcloud iam service-accounts create "github-automation" \
      --project "${GCP_PROJECT_ID}" \
      --quiet
    echo "SA_GITHUB_AUTOMATION=\"github-automation\"" >> config.env
  else
    echo "Service account github-automation already exists"
  fi

  # Assign roles to the GitHub automation service account
  echo "Assigning roles to the GitHub automation service account"
  gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:github-automation@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/run.admin" \
    --quiet

  gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:github-automation@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountUser" \
    --quiet

  gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:github-automation@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
    --role="roles/artifactregistry.writer" \
    --quiet

  # Command to add IAM policy binding
  gcloud iam service-accounts add-iam-policy-binding \
    "github-automation@${GCP_PROJECT_ID}.iam.gserviceaccount.com" \
    --project="${GCP_PROJECT_ID}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/${WORKLOAD_IDENTITY_POOL}" \
    --quiet

  # Create WIF POOL only if it doesn't exist
  if ! gcloud iam workload-identity-pools describe "deployer-pool" \
      --project="${GCP_PROJECT_ID}" \
      --location="global" \
      --quiet 2>/dev/null; then
      echo "Creating workload-identity-pool in project ${GCP_PROJECT_ID}"
      gcloud iam workload-identity-pools create "deployer-pool" \
        --project="${GCP_PROJECT_ID}" \
        --location="global" \
        --display-name="Deployer Pool" \
        --quiet
  else
      echo "Workload identity pool 'deployer-pool' already exists"
  fi

  # Fetch WIF Pool Name
  WIF_POOL_NAME=$(gcloud iam workload-identity-pools describe "deployer-pool" \
    --project="${GCP_PROJECT_ID}" \
    --location="global" \
    --format="value(name)")

# Create Workload Identity PROVIDER only if it doesn't exist
  if ! gcloud iam workload-identity-pools providers list \
    --project="${GCP_PROJECT_ID}" \
    --location="global" \
    --workload-identity-pool="deployer-pool" \
    --format="value(name)" | grep -q "github"; then
    echo "Creating GitHub workload identity provider"
    gcloud iam workload-identity-pools providers create-oidc "github" \
      --project="${GCP_PROJECT_ID}" \
      --location="global" \
      --workload-identity-pool="deployer-pool" \
      --issuer-uri="https://token.actions.githubusercontent.com" \
      --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
      --attribute-condition="assertion.repository_owner == '${GITHUB_ORG}'" \
      --quiet
  else
    echo "GitHub workload identity provider already exists"
  fi

  # Create Docker repository in Artifact Registry if it doesn't exist
  if ! gcloud artifacts repositories list \
    --project="${GCP_PROJECT_ID}" \
    --location="${SERVICE_REGION}" \
    --format="value(name)" | grep -q "docker"; then
    echo "Creating Docker repository in Artifact Registry"
    gcloud artifacts repositories create docker \
      --project="${GCP_PROJECT_ID}" \
      --repository-format=docker \
      --location="${SERVICE_REGION}" \
      --description="Docker repository for ${REPO_NAME}" \
      --quiet
  else
    echo "Docker repository 'docker' already exists in Artifact Registry"
  fi

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
