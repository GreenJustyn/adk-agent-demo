#!/bin/bash
# =============================================================================
# Standalone GCP Cleanup Script: Demo ADK Agent
# Removes the Cloud Run service and local artifacts.
# =============================================================================

set -e

echo "========================================================================="
echo "🧹 Executing Standalone GCP Cleanup: Demo ADK Agent"
echo "========================================================================="

PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
  echo "❌ Error: No default GCP project found. Run 'gcloud config set project [PROJECT_ID]'."
  exit 1
fi

echo "🗑️ Deleting Cloud Run Service: demo-adk-agent..."
MAIN_REGION=$(gcloud run services list --filter="metadata.name:demo-adk-agent" --format="value(region)" 2>/dev/null | head -n 1)
if [ -n "$MAIN_REGION" ]; then
  gcloud run services delete demo-adk-agent --region="$MAIN_REGION" --quiet 2>/dev/null && echo " ✅ Cloud Run service deleted." || echo " ⚠️ Failed to delete service."
else
  echo " ⚠️ Cloud Run service 'demo-adk-agent' not found."
fi

echo "🤖 Cleaning up Agent registration from Gemini Enterprise..."
TOKEN=$(gcloud auth print-access-token 2>/dev/null || gcloud auth application-default print-access-token 2>/dev/null)
if [ -n "$TOKEN" ]; then
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

  for ((i=0; i<APP_COUNT; i++)); do
    E_NAME="${APP_NAMES[$i]}"
    LOC="${APP_LOCS[$i]}"
    APP_ID=$(echo "$E_NAME" | awk -F'/' '{print $NF}')
    ENDPOINT="discoveryengine.googleapis.com"
    if [ "$LOC" != "global" ]; then ENDPOINT="${LOC}-discoveryengine.googleapis.com"; fi

    AGENTS_LIST_URL="https://$ENDPOINT/v1alpha/projects/$PROJECT_ID/locations/$LOC/collections/default_collection/engines/$APP_ID/assistants/default_assistant/agents?pageSize=100"
    AGENTS_JSON=$(curl -s -H "Authorization: Bearer $TOKEN" -H "X-Goog-User-Project: $PROJECT_ID" "$AGENTS_LIST_URL")

    for AGENT_NAME in $(echo "$AGENTS_JSON" | jq -r '.agents[]? | select(.displayName == "Demo ADK Agent") | .name'); do
      if [ -n "$AGENT_NAME" ]; then
        echo "   🗑️ Deleting agent registration in $LOC ($APP_ID): $AGENT_NAME"
        curl -s --fail -X DELETE -H "Authorization: Bearer $TOKEN" -H "X-Goog-User-Project: $PROJECT_ID" "https://$ENDPOINT/v1alpha/$AGENT_NAME" >/dev/null || true
      fi
    done
  done
else
  echo " ⚠️ Skipping agent registration cleanup due to missing authentication token."
fi

echo "🐳 Deleting container image from Artifact Registry..."
IMAGE_URI="us-central1-docker.pkg.dev/$PROJECT_ID/cloud-run-source-deploy/demo-adk-agent:latest"
gcloud artifacts docker images delete "$IMAGE_URI" --quiet 2>/dev/null && echo " ✅ Artifact Registry image deleted." || echo " ⚠️ No Artifact Registry image found to delete."

echo "✅ Uninstallation complete."
