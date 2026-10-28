#!/usr/bin/env bash
# =============================================================================
# run_all_tasks.sh
# Automated end-to-end execution script for:
# "Observe and Secure a Multi-Agent System" (Tasks 1 - 9)
# =============================================================================

set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"
export PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
export LOCATION="${LOCATION:-us-central1}"
export PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"

echo "=================================================================="
echo "Project ID     : ${PROJECT_ID}"
echo "Project Number : ${PROJECT_NUMBER}"
echo "Location       : ${LOCATION}"
echo "=================================================================="

echo ""
echo ">>> [Task 1] Enabling Observability, Discovery, and Security APIs..."
gcloud services enable \
  observability.googleapis.com \
  cloudtrace.googleapis.com \
  telemetry.googleapis.com \
  apphub.googleapis.com \
  apptopology.googleapis.com \
  agentregistry.googleapis.com \
  cloudasset.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  --project="${PROJECT_ID}"

echo ""
echo ">>> [Task 2] Granting roles/telemetry.tracesWriter to salesforce-agent SA..."
export SF_SA="$(gcloud run services describe salesforce-agent \
  --region="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --format='value(spec.template.spec.serviceAccountName)')"
echo "salesforce-agent service account: ${SF_SA}"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SF_SA}" \
  --role="roles/telemetry.tracesWriter" \
  --condition=None >/dev/null

echo ">>> [Task 2] Generating traffic to emit OpenTelemetry traces..."
export RE_NAME="$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines" \
  | jq -r '.reasoningEngines[] | select(.displayName=="github-agent") | .name')"
export GITHUB_RE_URL="https://${LOCATION}-aiplatform.googleapis.com/v1/${RE_NAME}"
export SF_URL="$(gcloud run services describe salesforce-agent \
  --region="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --format='value(status.url)')"

agents-cli run \
  --url "${GITHUB_RE_URL}" \
  --mode adk \
  --app-name app \
  "Hello, what tools do you have?" || true

agents-cli run \
  --url "${SF_URL}" \
  --mode adk \
  --app-name app \
  "Search Salesforce documents for onboarding" || true

echo ""
echo ">>> [Task 3] Confirming Agent Runtime agent discovery in Agent Registry & App Hub..."
gcloud alpha agent-registry agents list \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --format="table(displayName)"

export ACCESS_TOKEN="$(gcloud auth print-access-token)"
curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "https://apphub.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/discoveredWorkloads" \
  | jq -r '.discoveredWorkloads[] | "\(.workloadProperties.functionalType.type // "-")\t\(.workloadReference.uri)"'

echo ""
echo ">>> [Task 4] Creating Discovery Engine service identity & granting Cloud Run Invoker..."
gcloud beta services identity create \
  --service=discoveryengine.googleapis.com \
  --project="${PROJECT_ID}"

gcloud run services add-iam-policy-binding salesforce-agent \
  --region="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
  --role="roles/run.invoker" >/dev/null

echo ">>> [Task 4] Fetching salesforce-agent A2A card and registering in Agent Registry..."
export ID_TOKEN="$(gcloud auth print-identity-token)"
curl -s -H "Authorization: Bearer ${ID_TOKEN}" \
  "${SF_URL}/a2a/app/.well-known/agent-card.json" \
  -o salesforce_card.json

gcloud alpha agent-registry services create salesforce-agent \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --agent-spec-type=a2a-agent-card \
  --agent-spec-content=salesforce_card.json

echo ""
echo ">>> [Task 5] Registering GitHub MCP server (github-mcp) in Agent Registry..."
gcloud alpha agent-registry services create github-mcp \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --mcp-server-spec-type=no-spec \
  --interfaces="url=https://api.githubcopilot.com/mcp/,protocolBinding=JSONRPC"

gcloud alpha agent-registry mcp-servers list \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}"

echo ""
echo ">>> [Task 9] Ensuring least-privilege roles and removing roles/editor from ${SF_SA}..."
for ROLE in roles/aiplatform.user roles/telemetry.tracesWriter roles/logging.logWriter roles/cloudtrace.agent; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SF_SA}" \
    --role="${ROLE}" \
    --condition=None >/dev/null
done

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SF_SA}" \
  --role="roles/editor" >/dev/null || true

echo ">>> Verifying final IAM roles for ${SF_SA}:"
gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.members:${SF_SA}" \
  --format="value(bindings.role)"

echo ""
echo "=================================================================="
echo "All tasks (Tasks 1 - 9) completed and verified successfully!"
echo "=================================================================="
