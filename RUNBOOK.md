# Operational Runbook — Observe and Secure a Multi-Agent System

This runbook provides a fast, copy-paste execution sequence, verification checks for every lab objective, and troubleshooting steps.

---

## 1. Fast-Track Execution (Automated Script)

You can execute all required CLI steps (Tasks 1–9) automatically by running:

```bash
bash scripts/run_all_tasks.sh
```

Or follow the manual section-by-section commands below.

---

## 2. Step-by-Step CLI Runbook

### Step 0: Initialize Environment Variables

```bash
export PROJECT_ID=$(gcloud config get-value project)
export LOCATION=us-central1
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')
export PATH="${HOME}/.local/bin:${PATH}"

export SF_SA=$(gcloud run services describe salesforce-agent \
  --region=${LOCATION} \
  --project=${PROJECT_ID} \
  --format='value(spec.template.spec.serviceAccountName)')

export SF_URL=$(gcloud run services describe salesforce-agent \
  --region=${LOCATION} \
  --project=${PROJECT_ID} \
  --format='value(status.url)')

export RE_NAME=$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines" \
  | jq -r '.reasoningEngines[] | select(.displayName=="github-agent") | .name')

export GITHUB_RE_URL="https://${LOCATION}-aiplatform.googleapis.com/v1/${RE_NAME}"

cat <<EOF
PROJECT_ID     = ${PROJECT_ID}
PROJECT_NUMBER = ${PROJECT_NUMBER}
LOCATION       = ${LOCATION}
SF_SA          = ${SF_SA}
SF_URL         = ${SF_URL}
GITHUB_RE_URL  = ${GITHUB_RE_URL}
EOF
```

---

### Step 1: Enable Required Google Cloud APIs (Task 1)

```bash
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
  --project=${PROJECT_ID}
```

---

### Step 2: Grant `roles/telemetry.tracesWriter` & Emit Traces (Task 2)

```bash
# Grant Cloud Telemetry Traces Writer role to salesforce-agent SA
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:${SF_SA}" \
  --role="roles/telemetry.tracesWriter" \
  --condition=None

# Query github-agent on Agent Runtime
agents-cli run \
  --url "${GITHUB_RE_URL}" \
  --mode adk \
  --app-name app \
  "Hello, what tools do you have?"

# Query salesforce-agent on Cloud Run
agents-cli run \
  --url "${SF_URL}" \
  --mode adk \
  --app-name app \
  "Search Salesforce documents for onboarding"
```

---

### Step 3: Verify Auto-Discovery of Agent Runtime Agent (Task 3)

```bash
gcloud alpha agent-registry agents list \
  --location=${LOCATION} \
  --project=${PROJECT_ID} \
  --format="table(displayName)"

export TOKEN=$(gcloud auth print-access-token)
curl -s -H "Authorization: Bearer ${TOKEN}" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "https://apphub.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/discoveredWorkloads" \
  | jq -r '.discoveredWorkloads[] | "\(.workloadProperties.functionalType.type // "-")\t\(.workloadReference.uri)"'
```

---

### Step 4: Grant Discovery Engine Invoker Access & Register Cloud Run Agent (Task 4)

```bash
# Create Discovery Engine service agent identity
gcloud beta services identity create \
  --service=discoveryengine.googleapis.com \
  --project=${PROJECT_ID}

# Grant roles/run.invoker on salesforce-agent
gcloud run services add-iam-policy-binding salesforce-agent \
  --region=${LOCATION} \
  --project=${PROJECT_ID} \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
  --role="roles/run.invoker"

# Download A2A Agent Card
export ID_TOKEN=$(gcloud auth print-identity-token)
curl -s -H "Authorization: Bearer ${ID_TOKEN}" \
  "${SF_URL}/a2a/app/.well-known/agent-card.json" \
  -o salesforce_card.json

# Register salesforce-agent in Agent Registry
gcloud alpha agent-registry services create salesforce-agent \
  --location=${LOCATION} \
  --project=${PROJECT_ID} \
  --agent-spec-type=a2a-agent-card \
  --agent-spec-content=salesforce_card.json
```

---

### Step 5: Register GitHub MCP Server (Task 5)

```bash
gcloud alpha agent-registry services create github-mcp \
  --location=${LOCATION} \
  --project=${PROJECT_ID} \
  --mcp-server-spec-type=no-spec \
  --interfaces="url=https://api.githubcopilot.com/mcp/,protocolBinding=JSONRPC"

gcloud alpha agent-registry mcp-servers list \
  --location=${LOCATION} \
  --project=${PROJECT_ID}
```

---

### Step 6: Remediate Over-Privileged Service Account to Least Privilege (Tasks 7–9)

```bash
# Ensure required narrow roles are bound before removing roles/editor
for ROLE in roles/aiplatform.user roles/telemetry.tracesWriter roles/logging.logWriter roles/cloudtrace.agent; do
  gcloud projects add-iam-policy-binding ${PROJECT_ID} \
    --member="serviceAccount:${SF_SA}" \
    --role="${ROLE}" \
    --condition=None >/dev/null
done

# Remove over-broad roles/editor binding
gcloud projects remove-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:${SF_SA}" \
  --role="roles/editor"

# Verify roles/editor is removed (should output nothing)
gcloud projects get-iam-policy ${PROJECT_ID} \
  --flatten="bindings[].members" \
  --filter="bindings.members:${SF_SA} AND bindings.role:roles/editor" \
  --format="value(bindings.role)"

# Verify remaining roles on SF_SA
gcloud projects get-iam-policy ${PROJECT_ID} \
  --flatten="bindings[].members" \
  --filter="bindings.members:${SF_SA}" \
  --format="value(bindings.role)"
```

---

## 3. Objective Verification Checklist

| Checkpoint | Verification Command | Expected State |
|------------|---------------------|----------------|
| **Task 2**: Grant trace-writer role | `gcloud projects get-iam-policy ${PROJECT_ID} --flatten="bindings[].members" --filter="bindings.members:${SF_SA} AND bindings.role:roles/telemetry.tracesWriter" --format="value(bindings.role)"` | `roles/telemetry.tracesWriter` |
| **Task 4a**: Discovery Engine invoker access | `gcloud run services get-iam-policy salesforce-agent --region=${LOCATION} --project=${PROJECT_ID}` | `service-<PROJECT_NUMBER>@gcp-sa-discoveryengine.iam.gserviceaccount.com` has `roles/run.invoker` |
| **Task 4b**: Register Cloud Run agent | `gcloud alpha agent-registry agents list --location=${LOCATION} --project=${PROJECT_ID} --format="value(displayName)"` | Includes `salesforce_agent` and `github-agent` |
| **Task 5**: Register GitHub MCP server | `gcloud alpha agent-registry mcp-servers list --location=${LOCATION} --project=${PROJECT_ID}` | Lists `github-mcp` (`https://api.githubcopilot.com/mcp/`) |
| **Task 9**: Remediate over-privileged agent | `gcloud projects get-iam-policy ${PROJECT_ID} --flatten="bindings[].members" --filter="bindings.members:${SF_SA}" --format="value(bindings.role)"` | Only `roles/aiplatform.user`, `roles/cloudtrace.agent`, `roles/logging.logWriter`, `roles/telemetry.tracesWriter` (no `roles/editor`) |

---

## 4. Troubleshooting Guide

| Symptom / Error | Root Cause | Resolution |
|-----------------|------------|------------|
| `agents-cli: command not found` | `~/.local/bin` is not in `PATH` | Run `export PATH="${HOME}/.local/bin:${PATH}"` |
| `agents-cli run` fails with `404` or invalid URL on `github-agent` | `:query` suffix was left on the Reasoning Engine URL | Strip `:query` from the end of the URL so it ends with `/reasoningEngines/<ID>` |
| `gcloud alpha agent-registry services create` fails on `salesforce_card.json` | Empty or invalid JSON in `salesforce_card.json` (e.g., missing identity token when curling Cloud Run) | Ensure `TOKEN=$(gcloud auth print-identity-token)` is passed in `Authorization: Bearer ${TOKEN}` and verify `cat salesforce_card.json` is valid JSON |
| Cloud Run agent runs fine but no spans appear in Cloud Trace | Missing `roles/telemetry.tracesWriter` on the Cloud Run service account | Note that the OTLP Telemetry API (`telemetry.googleapis.com`) requires `roles/telemetry.tracesWriter` in addition to `roles/cloudtrace.agent` |
| Policy Analyzer still shows `roles/editor` right after removal | Cloud Asset Inventory ingestion lag (up to ~60 seconds) | Use `gcloud projects get-iam-policy` for immediate live IAM verification, then wait 1 minute and re-run Policy Analyzer |
