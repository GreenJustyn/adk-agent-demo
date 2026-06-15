# 1. Grant Cloud Build Editor (required to submit builds)
gcloud projects add-iam-policy-binding onenz-sbx-genai-gedemo-0 \
    --member="user:justyngreen@google.com" \
    --role="roles/cloudbuild.builds.editor"

# 2. Grant Storage Object Admin (required to upload source code to the build bucket)
gcloud projects add-iam-policy-binding onenz-sbx-genai-gedemo-0 \
    --member="user:justyngreen@google.com" \
    --role="roles/storage.objectAdmin"

# 3. Grant Artifact Registry Admin (required to create the registry and push images)
gcloud projects add-iam-policy-binding onenz-sbx-genai-gedemo-0 \
    --member="user:justyngreen@google.com" \
    --role="roles/artifactregistry.admin"

# 4. Grant Cloud Run Admin and Service Account User (required to deploy to Cloud Run)
gcloud projects add-iam-policy-binding onenz-sbx-genai-gedemo-0 \
    --member="user:justyngreen@google.com" \
    --role="roles/run.admin"

# Get the project number for onenz-sbx-genai-gedemo-0
PROJECT_NUMBER=$(gcloud projects describe onenz-sbx-genai-gedemo-0 --format="value(projectNumber)")

gcloud iam service-accounts add-iam-policy-binding \
    "${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --member="user:justyngreen@google.com" \
    --role="roles/iam.serviceAccountUser" \
    --project=onenz-sbx-genai-gedemo-0
