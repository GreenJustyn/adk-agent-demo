#!/bin/bash
# =============================================================================
# Standalone GCP Deployment Script: Demo ADK Agent
# Builds container image, deploys to Cloud Run, and registers to Gemini Enterprise.
# =============================================================================

set -e

# Configuration Variables
AGENT_MODEL="gemini-2.5-pro"
AGENT_MODEL_LITE="gemini-2.5-flash"

# BigQuery telemetry dataset configuration
DATASET_ID="melt_data_foundation_v04"

# Target GCP Project where the BigQuery dataset resides (falls back to active gcloud project if empty)
TARGET_PROJECT_ID=""


echo "========================================================================="
echo "🚀 Executing Standalone GCP Deployment: Demo ADK Agent"
echo "========================================================================="

# --- Check required tools ---
echo "⚙️ Checking required CLI tools..."
for tool in jq curl gcloud python3; do
  if ! command -v $tool >/dev/null 2>&1; then
    echo "❌ Error: $tool is not installed in your environment."
    exit 1
  fi
done

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
  echo "❌ Error: No default GCP project found. Run 'gcloud config set project [PROJECT_ID]'."
  exit 1
fi

TOKEN=$(gcloud auth print-access-token 2>/dev/null || gcloud auth application-default print-access-token 2>/dev/null)
if [ -z "$TOKEN" ]; then
  echo "❌ Error: Google Cloud credentials missing. Run 'gcloud auth login'."
  exit 1
fi

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null)

echo "📡 Enabling required GCP APIs..."
gcloud services enable \
  aiplatform.googleapis.com \
  bigquery.googleapis.com \
  discoveryengine.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  iam.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  --project="$PROJECT_ID" --quiet

echo "🔧 Enabling MCP service for BigQuery..."
gcloud beta services mcp enable bigquery.googleapis.com --project="$PROJECT_ID" 2>/dev/null || true

echo "🤖 Initializing Discovery Engine Service Agent..."
gcloud beta services identity create --service=discoveryengine.googleapis.com --project="$PROJECT_ID" 2>/dev/null || true

COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
echo "🔐 Granting necessary IAM roles to Cloud Run service account ($COMPUTE_SA)..."
for role in "roles/mcp.toolUser" "roles/serviceusage.serviceUsageConsumer" "roles/bigquery.jobUser" "roles/bigquery.dataViewer" "roles/aiplatform.user" "roles/run.invoker"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$COMPUTE_SA" --role="$role" --condition=None --quiet >/dev/null 2>&1 || true
done

DISCOVERY_ENGINE_SA="service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com"
echo "🔐 Granting run.invoker to Discovery Engine Service Agent ($DISCOVERY_ENGINE_SA)..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$DISCOVERY_ENGINE_SA" --role="roles/run.invoker" --condition=None --quiet >/dev/null 2>&1 || true

echo "⏳ Pausing for 15 seconds to allow IAM role propagation across Google Cloud metadata systems..."
sleep 15
echo "✅ IAM permissions stabilized."

echo "📦 Verifying/creating Artifact Registry repository 'cloud-run-source-deploy'..."
gcloud artifacts repositories create cloud-run-source-deploy \
    --repository-format=docker \
    --location=us-central1 \
    --description="Repository for Cloud Run deployments" \
    --project="$PROJECT_ID" \
    --quiet 2>/dev/null || true

echo "🐳 Building container image and submitting to Artifact Registry..."
SERVICE_NAME="demo-adk-agent"
IMAGE_URI="us-central1-docker.pkg.dev/$PROJECT_ID/cloud-run-source-deploy/$SERVICE_NAME:latest"
gcloud builds submit --tag "$IMAGE_URI" . --quiet

echo "🚀 Deploying agent service to Cloud Run..."
if [ -z "$TARGET_PROJECT_ID" ]; then
  TARGET_PROJECT_ID="$PROJECT_ID"
fi
CR_ENV="GOOGLE_CLOUD_PROJECT=$PROJECT_ID,GOOGLE_CLOUD_LOCATION=us-central1,AGENT_MODEL=$AGENT_MODEL,AGENT_MODEL_LITE=$AGENT_MODEL_LITE,ADK_ENABLE_MCP_GRACEFUL_ERROR_HANDLING=1,TARGET_PROJECT_ID=$TARGET_PROJECT_ID,DATASET_ID=$DATASET_ID"
gcloud run deploy "$SERVICE_NAME" \
    --image "$IMAGE_URI" --platform managed --region us-central1 --memory "4Gi" --cpu 2 \
    --no-cpu-throttling --cpu-boost --no-allow-unauthenticated --ingress internal \
    --timeout 900 --service-account "$COMPUTE_SA" --set-env-vars="$CR_ENV" --quiet

SERVICE_URL=$(gcloud run services list --filter="metadata.name:$SERVICE_NAME" --format="value(status.url)" | head -n 1)
echo "✅ Cloud Run service deployed successfully at: $SERVICE_URL"

echo "🤖 Registering Agent definition to Gemini Enterprise..."
APP_COUNT=0
APP_NAMES=()
APP_LOCS=()
for LOC in "global" "us" "eu"; do
  ENDPOINT="discoveryengine.googleapis.com"
  if [ "$LOC" != "global" ]; then ENDPOINT="${LOC}-discoveryengine.googleapis.com"; fi
  JSON=$(curl -s -H "Authorization: Bearer $TOKEN" -H "X-Goog-User-Project: $PROJECT_ID" "https://$ENDPOINT/v1alpha/projects/$PROJECT_ID/locations/$LOC/collections/default_collection/engines")
  for E_NAME in $(echo "$JSON" | jq -r '.engines[]? | select(.searchEngineConfig.requiredSubscriptionTier == "SUBSCRIPTION_TIER_SEARCH_AND_ASSISTANT") | .name'); do
    APP_NAMES+=("$E_NAME")
    APP_LOCS+=("$LOC")
    APP_COUNT=$((APP_COUNT + 1))
  done
done

if [ $APP_COUNT -gt 0 ]; then
  SELECTED_APP_ID=$(echo "${APP_NAMES[0]}" | awk -F'/' '{print $NF}')
  SELECTED_LOC="${APP_LOCS[0]}"
  ENDPOINT="discoveryengine.googleapis.com"
  if [ "$SELECTED_LOC" != "global" ]; then ENDPOINT="${SELECTED_LOC}-discoveryengine.googleapis.com"; fi
  
  AGENTS_LIST_URL="https://$ENDPOINT/v1alpha/projects/$PROJECT_ID/locations/$SELECTED_LOC/collections/default_collection/engines/$SELECTED_APP_ID/assistants/default_assistant/agents?pageSize=100"
  AGENTS_JSON=$(curl -s -H "Authorization: Bearer $TOKEN" -H "X-Goog-User-Project: $PROJECT_ID" "$AGENTS_LIST_URL")
  
  echo "🧹 Cleaning up any previously registered instances of Demo ADK Agent..."
  for AGENT_NAME in $(echo "$AGENTS_JSON" | jq -r '.agents[]? | select(.displayName == "Demo ADK Agent") | .name'); do
    if [ -n "$AGENT_NAME" ]; then
      echo "   🗑️ Deleting previous agent registration: $AGENT_NAME"
      curl -s --fail -X DELETE -H "Authorization: Bearer $TOKEN" -H "X-Goog-User-Project: $PROJECT_ID" "https://$ENDPOINT/v1alpha/$AGENT_NAME" >/dev/null || true
    fi
  done
  
  echo "🤖 Registering fresh agent instance..."
  REG_URL="https://$ENDPOINT/v1alpha/projects/$PROJECT_ID/locations/$SELECTED_LOC/collections/default_collection/engines/$SELECTED_APP_ID/assistants/default_assistant/agents"
  REG_PAYLOAD=$(jq -n --arg name "demo-adk-agent" --arg url "$SERVICE_URL/a2a/app" '{
    name: $name,
    displayName: "Demo ADK Agent",
    description: "Demo ADK Agent",
    a2aAgentDefinition: {
      jsonAgentCard: ("{\"protocolVersion\": \"1.0\", \"name\": \"app\", \"description\": \"Demo ADK Agent\", \"url\": \"" + $url + "\", \"version\": \"1.0.0\", \"defaultInputModes\": [\"text/plain\"], \"defaultOutputModes\": [\"text/plain\", \"application/json\"], \"capabilities\": {\"streaming\": true, \"extensions\": [{\"uri\": \"https://a2ui.org/a2a-extension/a2ui/v0.8\"}]}, \"preferredTransport\": \"JSONRPC\", \"skills\": [{\"id\": \"bigquery\", \"name\": \"BigQuery Operations\", \"description\": \"Investigates SIEM/MELT telemetry and performs graph analysis on service dependencies.\", \"tags\": []}]}")
    },
    sharingConfig: {
      scope: "ALL_USERS"
    }
  }')
  
  REG_RES=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "X-Goog-User-Project: $PROJECT_ID" -d "$REG_PAYLOAD" "$REG_URL")
  echo "🎉 Agent successfully registered to Gemini Enterprise!"
  
  echo ""
  echo "========================================================================="
  echo "💬 Chat with your deployed agent in Gemini Enterprise:"
  echo " 👉 https://console.cloud.google.com/gemini-enterprise/locations/$SELECTED_LOC/engines/$SELECTED_APP_ID/overview/dashboard?&project=$PROJECT_ID"
  echo "========================================================================="
else
  echo "⚠️ No eligible Gemini Enterprise apps found in this project. Please create an App Engine in the console to chat."
  echo " 👉 https://console.cloud.google.com/gemini-enterprise/overview?&project=$PROJECT_ID"
fi

echo "✅ Deployment script execution completed."
