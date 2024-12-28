#!/bin/bash

# Set strict error handling
set -euo pipefail

# Function to create GitHub Actions service account
create_github_actions_service_account() {
    local service_account_email="github-actions@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
    
    # Check if service account already exists
    if ! gcloud iam service-accounts list \
        --project="${GCP_PROJECT_ID}" \
        --filter="email:${service_account_email}" \
        --format="value(email)" | grep -q "${service_account_email}"; then
        
        echo "Creating service account: github-actions"
        gcloud iam service-accounts create "github-actions" \
            --project "${GCP_PROJECT_ID}" \
            --quiet
    else
        echo "Service account github-actions already exists"
    fi
}

# Function to set up Workload Identity for GitHub Actions
setup_workload_identity() {
    local workload_identity_pool="deploy-pool"
    local workload_identity_provider="github-provider"
    
    # Create Workload Identity Pool
    gcloud iam workload-identity-pools create "${workload_identity_pool}" \
        --project="${GCP_PROJECT_ID}" \
        --location="global" \
        --display-name="deployer pool"

    # Create Workload Identity Provider
    gcloud iam workload-identity-pools providers create-oidc "${workload_identity_provider}" \
        --project="${GCP_PROJECT_ID}" \
        --location="global" \
        --workload-identity-pool="${workload_identity_pool}" \
        --display-name="My GitHub repo Provider" \
        --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
        --attribute-condition="assertion.repository_owner == '${GITHUB_ORG}'" \
        --issuer-uri="https://token.actions.githubusercontent.com"

    # Get the Workload Identity Provider resource name
    WORKLOAD_IDENTITY_PROVIDER=$(gcloud iam workload-identity-pools providers describe "${workload_identity_provider}" \
        --project="${GCP_PROJECT_ID}" \
        --location="global" \
        --workload-identity-pool="${workload_identity_pool}" \
        --format="value(name)")

    echo "Workload Identity Provider Resource Name: ${WORKLOAD_IDENTITY_PROVIDER}"
}

# Function to add IAM policy bindings
configure_iam_permissions() {
    local service_account_email="github-actions@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
    local project="julius-private-sandbox"
    local service_account="langgraph-host@${project}.iam.gserviceaccount.com"
    
    # Bind service account to Workload Identity
    gcloud iam service-accounts add-iam-policy-binding "${service_account_email}" \
        --project="${GCP_PROJECT_ID}" \
        --role="roles/iam.workloadIdentityUser" \
        --member="principalSet://iam.googleapis.com/projects/${GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/deploy-pool/attribute.repository/${GITHUB_REPO}"

    # Grant Artifact Registry write permissions
    gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
        --member="serviceAccount:${service_account_email}" \
        --role="roles/artifactregistry.writer"

    # Grant Cloud Run admin permissions
    gcloud projects add-iam-policy-binding "${project}" \
        --member="serviceAccount:${service_account}" \
        --role="roles/run.admin"

    # Grant Secret Manager access
    gcloud projects add-iam-policy-binding "${project}" \
        --member="serviceAccount:${service_account}" \
        --role="roles/secretmanager.secretAccessor"

    # Allow GitHub Actions to impersonate service account
    gcloud iam service-accounts add-iam-policy-binding "${service_account}" \
        --member="serviceAccount:${service_account_email}" \
        --role="roles/iam.serviceAccountUser" \
        --project="${project}"
}

# Main setup function
setup() {
    # Validate required environment variables
    : "${GCP_PROJECT_ID:?Need to set GCP_PROJECT_ID}"
    : "${GCP_PROJECT_NUMBER:?Need to set GCP_PROJECT_NUMBER}"
    : "${GITHUB_ORG:?Need to set GITHUB_ORG}"
    : "${GITHUB_REPO:?Need to set GITHUB_REPO}"

    # Execute setup steps
    create_github_actions_service_account
    setup_workload_identity
    configure_iam_permissions
}

# Run setup if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup
fi
