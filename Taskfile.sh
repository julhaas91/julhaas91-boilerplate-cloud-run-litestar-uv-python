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
  pip install uv
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
  # NOTE: all other env variables are imported via "source config.env" (line 5)

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
  # SOURCE: https://github.com/google-github-actions/auth#indirect-wif
  # info: all other env variables are imported via "source config.env" (line 5)
  echo "--- SETTING UP GOOGLE CLOUD INFRASTRUCTURE ---"
  echo "creating service account: ${CLOUD_RUN_SERVICE_ACCOUNT}"
  uv run gcloud iam service-accounts create "${CLOUD_RUN_SERVICE_ACCOUNT}" \
  --project "${GCP_PROJECT_ID}"

  echo "writing 'SERVICE_ACCOUNT=${CLOUD_RUN_SERVICE_ACCOUNT}' to config.env"
  echo "SERVICE_ACCOUNT=\"${CLOUD_RUN_SERVICE_ACCOUNT}\"" >> config.env

  echo "creating workload-identity-pool in project ${GCP_PROJECT_ID}"
  uv run gcloud iam workload-identity-pools create "github" \
  --project="${GCP_PROJECT_ID}" \
  --location="global" \
  --display-name="GitHub Actions Pool"

  echo "checking for created workload-identity-pools in project ${GCP_PROJECT_ID}"
  WIF_POOL_NAME=$(uv run gcloud iam workload-identity-pools describe "github" \
  --project="${GCP_PROJECT_ID}" \
  --location="global" \
  --format="value(name)")
  echo "success: workload-identity-pool ${WIF_POOL_NAME} exists"

  REPO_NAME=$(cat pyproject.toml | grep "^name\s*=" | cut -d'=' -f2 | tr -d ' "' | head -n1)

  echo "adding iam-policy-binding for ${CLOUD_RUN_SERVICE_ACCOUNT} in project ${GCP_PROJECT_ID}"
  uv run "gcloud iam service-accounts add-iam-policy-binding ${CLOUD_RUN_SERVICE_ACCOUNT}" \
    --project="${GCP_PROJECT_ID}" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/${WIF_POOL_NAME}/attribute.repository/${GITHUB_ORG}/${REPO_NAME}"

  WIF_PROVIDER_NAME=$(uv run gcloud iam workload-identity-pools providers describe "${REPO_NAME}" \
  --project="${GCP_PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="github" \
  --format="value(name)")

  echo "checking for workload-identity-provider name in project ${GCP_PROJECT_ID}"
  echo "success: workload-identity-provider ${WIF_PROVIDER_NAME} was retrieved"
  echo "writing 'WIF_PROVIDER_NAME=${WIF_PROVIDER_NAME}' to config.env"
  echo "WIF_PROVIDER_NAME=\"${WIF_PROVIDER_NAME}\"" >> config.env
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
