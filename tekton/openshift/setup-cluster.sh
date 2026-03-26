#!/bin/bash
# =============================================================================
# OpenShift/ROSA Cluster Setup for sigstore-a2a Tekton Pipelines
# =============================================================================
#
# This script configures an OpenShift cluster with all permissions needed
# for signing and verifying A2A Agent Cards using Sigstore.
#
# Usage:
#   ./setup-cluster.sh [--namespace <namespace>] [--rosa] [--teardown]
#
# Options:
#   --namespace   Namespace for Tekton resources (default: sigstore-a2a)
#   --rosa        Enable ROSA-specific configurations (AWS IRSA)
#   --teardown    Remove all resources instead of creating them
#   --dry-run     Print resources without applying
#
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
NAMESPACE="sigstore-a2a"
ROSA_MODE=false
TEARDOWN=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --rosa)
      ROSA_MODE=true
      shift
      ;;
    --teardown)
      TEARDOWN=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      head -25 "$0" | tail -20
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Helper functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

apply_or_delete() {
  if [ "$DRY_RUN" = true ]; then
    echo "---"
    cat
    echo ""
  elif [ "$TEARDOWN" = true ]; then
    kubectl delete -f - --ignore-not-found=true || true
  else
    kubectl apply -f -
  fi
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

log_info "Running pre-flight checks..."

# Check if logged into OpenShift
if ! oc whoami &>/dev/null; then
  log_error "Not logged into OpenShift. Run 'oc login' first."
  exit 1
fi

CLUSTER_NAME=$(oc whoami --show-server | sed 's|https://api\.\([^:]*\).*|\1|')
log_info "Cluster: $CLUSTER_NAME"
log_info "User: $(oc whoami)"
log_info "Namespace: $NAMESPACE"

if [ "$TEARDOWN" = true ]; then
  log_warn "TEARDOWN MODE - Will delete all resources"
else
  log_info "Setup mode - Will create/update resources"
fi

echo ""

# =============================================================================
# STEP 1: NAMESPACE
# =============================================================================

log_info "Step 1: Creating namespace..."

apply_or_delete <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
    # Allow Tekton to run here
    operator.tekton.dev/enable-annotation: "true"
EOF

log_success "Namespace configured"

# =============================================================================
# STEP 2: INSTALL OPENSHIFT PIPELINES OPERATOR
# =============================================================================

log_info "Step 2: Checking OpenShift Pipelines Operator..."

if [ "$TEARDOWN" = false ] && [ "$DRY_RUN" = false ]; then
  # Check if OpenShift Pipelines is installed
  if ! oc get csv -n openshift-operators 2>/dev/null | grep -q "openshift-pipelines"; then
    log_info "Installing OpenShift Pipelines Operator..."
    
    apply_or_delete <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    
    log_info "Waiting for OpenShift Pipelines Operator to install..."
    
    # Wait for the CSV to be ready
    for i in {1..60}; do
      CSV_STATUS=$(oc get csv -n openshift-operators -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift Pipelines")].status.phase}' 2>/dev/null || echo "")
      if [ "$CSV_STATUS" = "Succeeded" ]; then
        log_info "Operator CSV ready"
        break
      fi
      echo -n "."
      sleep 5
    done
    echo ""
    
    # Wait for TektonConfig to be created and ready
    log_info "Waiting for TektonConfig to be ready..."
    for i in {1..60}; do
      if oc get tektonconfig config &>/dev/null; then
        CONFIG_STATUS=$(oc get tektonconfig config -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$CONFIG_STATUS" = "True" ]; then
          log_info "TektonConfig ready"
          break
        fi
      fi
      echo -n "."
      sleep 5
    done
    echo ""
    
    # Wait for Tekton CRDs to be available
    log_info "Waiting for Tekton CRDs to be available..."
    for i in {1..30}; do
      if oc get crd tasks.tekton.dev &>/dev/null && \
         oc get crd pipelines.tekton.dev &>/dev/null && \
         oc get crd pipelineruns.tekton.dev &>/dev/null; then
        log_info "Tekton CRDs available"
        break
      fi
      echo -n "."
      sleep 3
    done
    echo ""
    
  else
    log_info "OpenShift Pipelines already installed"
  fi
fi

# Final CRD check
if [ "$DRY_RUN" = false ]; then
  if ! oc get crd tasks.tekton.dev &>/dev/null; then
    log_error "Tekton CRDs not available. Please wait and run the script again."
    exit 1
  fi
fi

log_success "OpenShift Pipelines ready"

# =============================================================================
# STEP 3: SERVICE ACCOUNTS
# =============================================================================

log_info "Step 3: Creating service accounts..."

apply_or_delete <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sigstore-pipeline
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sigstore-signer
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
  annotations:
    # For ROSA with STS/IRSA - uncomment and configure
    # eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/sigstore-signer-role
EOF

log_success "Service accounts created"

# =============================================================================
# STEP 4: SECURITY CONTEXT CONSTRAINTS (OpenShift specific)
# =============================================================================

log_info "Step 4: Configuring Security Context Constraints..."

# OpenShift is more restrictive than vanilla K8s
# We need to allow Tekton tasks to run with appropriate permissions

apply_or_delete <<EOF
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: sigstore-a2a-scc
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
allowHostDirVolumePlugin: false
allowHostIPC: false
allowHostNetwork: false
allowHostPID: false
allowHostPorts: false
allowPrivilegeEscalation: false
allowPrivilegedContainer: false
allowedCapabilities: null
defaultAddCapabilities: null
fsGroup:
  type: MustRunAs
  ranges:
    - min: 1000
      max: 65534
groups: []
priority: null
readOnlyRootFilesystem: false
requiredDropCapabilities:
  - ALL
runAsUser:
  type: MustRunAsRange
  uidRangeMin: 1000
  uidRangeMax: 65534
seLinuxContext:
  type: MustRunAs
supplementalGroups:
  type: RunAsAny
users:
  - system:serviceaccount:${NAMESPACE}:sigstore-pipeline
  - system:serviceaccount:${NAMESPACE}:sigstore-signer
volumes:
  - configMap
  - downwardAPI
  - emptyDir
  - persistentVolumeClaim
  - projected
  - secret
EOF

# Also add to anyuid SCC for flexibility (common for Tekton)
if [ "$TEARDOWN" = false ] && [ "$DRY_RUN" = false ]; then
  oc adm policy add-scc-to-user anyuid -z sigstore-pipeline -n ${NAMESPACE} 2>/dev/null || true
  oc adm policy add-scc-to-user anyuid -z sigstore-signer -n ${NAMESPACE} 2>/dev/null || true
  oc adm policy add-scc-to-user nonroot -z sigstore-pipeline -n ${NAMESPACE} 2>/dev/null || true
  oc adm policy add-scc-to-user nonroot -z sigstore-signer -n ${NAMESPACE} 2>/dev/null || true
fi

log_success "Security Context Constraints configured"

# =============================================================================
# STEP 5: RBAC - CLUSTER ROLES
# =============================================================================

log_info "Step 5: Configuring RBAC..."

apply_or_delete <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: sigstore-a2a-pipeline-runner
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
rules:
  # Tekton resources
  - apiGroups: ["tekton.dev"]
    resources: ["*"]
    verbs: ["*"]
  # Core resources for deployments
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "secrets", "serviceaccounts"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods/log"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # Events for debugging
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch", "create"]
  # Persistent volumes for workspaces
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sigstore-a2a-pipeline-runner-binding
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
subjects:
  - kind: ServiceAccount
    name: sigstore-pipeline
    namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: sigstore-a2a-pipeline-runner
  apiGroup: rbac.authorization.k8s.io
---
# Role for managing deployments in target namespaces
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: sigstore-a2a-deployer
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
rules:
  - apiGroups: [""]
    resources: ["configmaps", "services"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: sigstore-a2a-deployer-binding
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
subjects:
  - kind: ServiceAccount
    name: sigstore-signer
    namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: sigstore-a2a-deployer
  apiGroup: rbac.authorization.k8s.io
EOF

log_success "RBAC configured"

# =============================================================================
# STEP 6: NETWORK POLICIES
# =============================================================================

log_info "Step 6: Configuring network policies..."

apply_or_delete <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-sigstore-egress
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # Allow DNS
    - to: []
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Allow HTTPS to Sigstore services
    - to: []
      ports:
        - protocol: TCP
          port: 443
    # Allow HTTP (for internal services)
    - to: []
      ports:
        - protocol: TCP
          port: 80
        - protocol: TCP
          port: 8080
EOF

log_success "Network policies configured"

# =============================================================================
# STEP 7: RESOURCE QUOTAS (Optional but recommended)
# =============================================================================

log_info "Step 7: Configuring resource quotas..."

apply_or_delete <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: sigstore-a2a-quota
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    persistentvolumeclaims: "10"
    pods: "20"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: sigstore-a2a-limits
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
spec:
  limits:
    - default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      type: Container
EOF

log_success "Resource quotas configured"

# =============================================================================
# STEP 8: ROSA-SPECIFIC CONFIGURATIONS
# =============================================================================

if [ "$ROSA_MODE" = true ]; then
  log_info "Step 8: Configuring ROSA-specific settings..."
  
  apply_or_delete <<EOF
# AWS Load Balancer Controller annotations for EventListener (if using webhooks)
apiVersion: v1
kind: Service
metadata:
  name: el-agent-card-listener
  namespace: ${NAMESPACE}
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
spec:
  type: LoadBalancer
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
  selector:
    eventlistener: agent-card-listener
EOF

  # Print IRSA setup instructions
  if [ "$DRY_RUN" = false ] && [ "$TEARDOWN" = false ]; then
    log_info ""
    log_info "=== ROSA IRSA Setup Instructions ==="
    log_info ""
    log_info "To enable keyless signing with AWS OIDC, run these commands:"
    log_info ""
    echo "  # Get your OIDC provider"
    echo "  OIDC_PROVIDER=\$(rosa describe cluster -c \$(oc whoami --show-server | sed 's|https://api\\.\\([^:]*\\).*|\\1|' | cut -d. -f1) --output json | jq -r '.aws.sts.oidc_endpoint_url' | sed 's|https://||')"
    echo ""
    echo "  # Create IAM role trust policy"
    echo "  cat > trust-policy.json << 'POLICY'"
    echo "  {"
    echo "    \"Version\": \"2012-10-17\","
    echo "    \"Statement\": [{"
    echo "      \"Effect\": \"Allow\","
    echo "      \"Principal\": {"
    echo "        \"Federated\": \"arn:aws:iam::\${AWS_ACCOUNT_ID}:oidc-provider/\${OIDC_PROVIDER}\""
    echo "      },"
    echo "      \"Action\": \"sts:AssumeRoleWithWebIdentity\","
    echo "      \"Condition\": {"
    echo "        \"StringEquals\": {"
    echo "          \"\${OIDC_PROVIDER}:sub\": \"system:serviceaccount:${NAMESPACE}:sigstore-signer\""
    echo "        }"
    echo "      }"
    echo "    }]"
    echo "  }"
    echo "  POLICY"
    echo ""
    echo "  # Create IAM role"
    echo "  aws iam create-role --role-name sigstore-signer-role --assume-role-policy-document file://trust-policy.json"
    echo ""
    echo "  # Annotate service account"
    echo "  oc annotate sa sigstore-signer -n ${NAMESPACE} eks.amazonaws.com/role-arn=arn:aws:iam::\${AWS_ACCOUNT_ID}:role/sigstore-signer-role"
    log_info ""
  fi
  
  log_success "ROSA configurations applied"
else
  log_info "Step 8: Skipping ROSA-specific settings (use --rosa to enable)"
fi

# =============================================================================
# STEP 9: INSTALL SIGSTORE-A2A TEKTON TASKS & PIPELINES
# =============================================================================

log_info "Step 9: Installing sigstore-a2a Tekton resources..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEKTON_DIR="$(dirname "$SCRIPT_DIR")"

if [ "$DRY_RUN" = false ]; then
  if [ "$TEARDOWN" = true ]; then
    kubectl delete -f "${TEKTON_DIR}/tasks/" -n ${NAMESPACE} --ignore-not-found=true || true
    kubectl delete -f "${TEKTON_DIR}/pipelines/" -n ${NAMESPACE} --ignore-not-found=true || true
    kubectl delete -f "${TEKTON_DIR}/triggers/" -n ${NAMESPACE} --ignore-not-found=true || true
  else
    kubectl apply -f "${TEKTON_DIR}/tasks/" -n ${NAMESPACE}
    kubectl apply -f "${TEKTON_DIR}/pipelines/" -n ${NAMESPACE}
    # Triggers are optional
    kubectl apply -f "${TEKTON_DIR}/triggers/" -n ${NAMESPACE} 2>/dev/null || log_warn "Triggers not applied (may need Tekton Triggers installed)"
  fi
fi

log_success "Tekton resources installed"

# =============================================================================
# STEP 10: CREATE SAMPLE WORKSPACE PVC
# =============================================================================

log_info "Step 10: Creating sample workspace PVC..."

apply_or_delete <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sigstore-workspace
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

log_success "Workspace PVC created"

# =============================================================================
# STEP 11: CREATE DEMO AGENT CARD CONFIGMAP
# =============================================================================

log_info "Step 11: Creating demo agent card ConfigMap..."

# Find the demo agent card - try multiple paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_CARD=""

# Try relative paths from script location
for CANDIDATE in \
  "${SCRIPT_DIR}/../../demo/weather-agent-card.json" \
  "${SCRIPT_DIR}/../demo/weather-agent-card.json" \
  "$(pwd)/demo/weather-agent-card.json" \
  "/Users/dekelly/sigstore-selfhost/sigstore-a2a/demo/weather-agent-card.json"; do
  if [ -f "$CANDIDATE" ]; then
    DEMO_CARD="$CANDIDATE"
    break
  fi
done

if [ "$TEARDOWN" = true ]; then
  kubectl delete configmap demo-agent-card -n ${NAMESPACE} --ignore-not-found=true || true
  log_success "Demo agent card ConfigMap deleted"
elif [ "$DRY_RUN" = true ]; then
  echo "Would create ConfigMap demo-agent-card from: $DEMO_CARD"
elif [ -n "$DEMO_CARD" ] && [ -f "$DEMO_CARD" ]; then
  log_info "Using demo card: $DEMO_CARD"
  oc create configmap demo-agent-card \
    --from-file=agent-card.json="$DEMO_CARD" \
    -n ${NAMESPACE} \
    --dry-run=client -o yaml | oc apply -f -
  log_success "Demo agent card ConfigMap created"
else
  log_warn "Demo agent card not found. Creating inline..."
  # Create a minimal agent card inline as fallback
  apply_or_delete <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: demo-agent-card
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/part-of: sigstore-a2a
data:
  agent-card.json: |
    {
      "name": "Demo Agent",
      "description": "A demo agent for testing sigstore-a2a signing",
      "version": "1.0.0",
      "url": "http://demo-agent.${NAMESPACE}.svc.cluster.local:8080",
      "capabilities": {
        "streaming": false,
        "pushNotifications": false
      },
      "defaultInputModes": ["text/plain"],
      "defaultOutputModes": ["text/plain"],
      "skills": [
        {
          "id": "hello",
          "name": "Hello World",
          "description": "A simple hello world skill",
          "tags": ["demo"],
          "examples": ["Say hello"],
          "inputModes": ["text/plain"],
          "outputModes": ["text/plain"]
        }
      ]
    }
EOF
  log_success "Demo agent card ConfigMap created (inline fallback)"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "============================================================================="
if [ "$TEARDOWN" = true ]; then
  log_success "TEARDOWN COMPLETE"
  echo ""
  echo "All sigstore-a2a resources have been removed from namespace: ${NAMESPACE}"
  echo ""
  echo "To fully clean up, also run:"
  echo "  oc delete namespace ${NAMESPACE}"
else
  log_success "SETUP COMPLETE"
  echo ""
  echo "Namespace: ${NAMESPACE}"
  echo ""
  echo "Quick Start:"
  echo "  # Run a test pipeline"
  echo "  oc project ${NAMESPACE}"
  echo ""
  echo "  tkn pipeline start agent-card-sign-verify-deploy \\"
  echo "    --param agent-card-path=agent-card.json \\"
  echo "    --param staging=true \\"
  echo "    --param deploy=false \\"
  echo "    --workspace name=shared-workspace,claimName=sigstore-workspace \\"
  echo "    --serviceaccount sigstore-pipeline \\"
  echo "    --showlog"
  echo ""
  echo "  # Or use the demo agent card"
  echo "  oc create -f - <<EOF"
  echo "  apiVersion: tekton.dev/v1"
  echo "  kind: PipelineRun"
  echo "  metadata:"
  echo "    generateName: demo-sign-"
  echo "    namespace: ${NAMESPACE}"
  echo "  spec:"
  echo "    pipelineRef:"
  echo "      name: agent-card-sign-verify-deploy"
  echo "    params:"
  echo "      - name: agent-card-path"
  echo "        value: agent-card.json"
  echo "      - name: staging"
  echo "        value: \"true\""
  echo "      - name: deploy"
  echo "        value: \"false\""
  echo "    workspaces:"
  echo "      - name: shared-workspace"
  echo "        configMap:"
  echo "          name: demo-agent-card"
  echo "    taskRunTemplate:"
  echo "      serviceAccountName: sigstore-pipeline"
  echo "  EOF"
  echo ""
  if [ "$ROSA_MODE" = true ]; then
    echo "ROSA Mode: Enabled"
    echo "  Don't forget to set up IRSA for keyless signing (see instructions above)"
  fi
fi
echo "============================================================================="
