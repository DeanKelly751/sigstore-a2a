#!/bin/bash
# =============================================================================
# Quick test script for sigstore-a2a pipeline on OpenShift
# =============================================================================

set -euo pipefail

NAMESPACE="${NAMESPACE:-sigstore-a2a}"
STAGING="${STAGING:-true}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Testing sigstore-a2a Pipeline on OpenShift ==="
echo "Namespace: ${NAMESPACE}"
echo "Staging mode: ${STAGING}"
echo ""

# Check if we're logged in
if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged into OpenShift. Run 'oc login' first."
  exit 1
fi

# Switch to namespace
oc project ${NAMESPACE} 2>/dev/null || {
  echo "ERROR: Namespace ${NAMESPACE} not found. Run setup-cluster.sh first."
  exit 1
}

# Check if pipeline exists
if ! oc get pipeline agent-card-sign-verify-deploy &>/dev/null; then
  echo "ERROR: Pipeline not found. Run setup-cluster.sh first."
  exit 1
fi

# Ensure demo-agent-card ConfigMap exists
if ! oc get configmap demo-agent-card -n ${NAMESPACE} &>/dev/null; then
  echo "Creating demo-agent-card ConfigMap..."
  DEMO_CARD="${SCRIPT_DIR}/../../demo/weather-agent-card.json"
  if [ -f "$DEMO_CARD" ]; then
    oc create configmap demo-agent-card \
      --from-file=agent-card.json="$DEMO_CARD" \
      -n ${NAMESPACE}
  else
    echo "ERROR: Demo agent card not found at $DEMO_CARD"
    exit 1
  fi
fi

echo "Starting pipeline run..."
echo ""

# Create PipelineRun
cat <<EOF | oc create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: test-sign-verify-
  namespace: ${NAMESPACE}
spec:
  pipelineRef:
    name: agent-card-sign-verify-deploy
  params:
    - name: agent-card-path
      value: agent-card.json
    - name: staging
      value: "${STAGING}"
    - name: deploy
      value: "false"
    - name: identity-provider
      value: ""
  workspaces:
    - name: shared-workspace
      configMap:
        name: demo-agent-card
  taskRunTemplate:
    serviceAccountName: sigstore-pipeline
EOF

echo ""
echo "Pipeline started! Watch logs with:"
echo "  tkn pipelinerun logs -f -n ${NAMESPACE}"
echo ""
echo "Or check status:"
echo "  tkn pipelinerun list -n ${NAMESPACE}"
