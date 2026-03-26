# OpenShift / ROSA Setup for sigstore-a2a

Scripts for setting up sigstore-a2a Tekton pipelines on OpenShift and ROSA (Red Hat OpenShift on AWS).

## Quick Start

```bash
# 1. Login to your OpenShift cluster
oc login --server=https://api.your-cluster.com:6443

# 2. Run the setup script
./setup-cluster.sh

# 3. Test the pipeline
./test-pipeline.sh

# 4. When done, tear down
./teardown-cluster.sh
```

## Scripts

| Script | Description |
|--------|-------------|
| `setup-cluster.sh` | Full cluster setup with all permissions |
| `teardown-cluster.sh` | Remove all sigstore-a2a resources |
| `test-pipeline.sh` | Quick test of the signing pipeline |

## Setup Script Options

```bash
./setup-cluster.sh [OPTIONS]

Options:
  --namespace NAME    Namespace for resources (default: sigstore-a2a)
  --rosa              Enable ROSA-specific configurations (AWS IRSA)
  --teardown          Remove all resources instead of creating
  --dry-run           Print resources without applying
  --help              Show help
```

## What Gets Installed

### Permissions & Security

1. **Namespace** - Dedicated namespace for sigstore-a2a
2. **OpenShift Pipelines** - Tekton operator (if not already installed)
3. **Service Accounts** - `sigstore-pipeline` and `sigstore-signer`
4. **Security Context Constraints** - Custom SCC for Tekton tasks
5. **RBAC** - ClusterRoles for pipeline execution and deployment
6. **Network Policies** - Allow egress to Sigstore services

### Tekton Resources

- All Tasks from `tekton/tasks/`
- All Pipelines from `tekton/pipelines/`
- Triggers from `tekton/triggers/` (if Tekton Triggers installed)
- Sample workspace PVC
- Demo agent card ConfigMap

## ROSA-Specific Setup

For ROSA clusters with AWS STS, use the `--rosa` flag:

```bash
./setup-cluster.sh --rosa
```

This configures:
- AWS Load Balancer annotations for EventListeners
- IRSA setup instructions for keyless signing

### Setting Up AWS IRSA for Keyless Signing

After running the setup script with `--rosa`, follow the printed instructions to:

1. Get your OIDC provider URL
2. Create an IAM role with trust policy
3. Annotate the service account

```bash
# Example (values will be printed by setup script)
OIDC_PROVIDER="rh-oidc.s3.us-east-1.amazonaws.com/xxxxx"
AWS_ACCOUNT_ID="123456789012"

# Create IAM role
aws iam create-role \
  --role-name sigstore-signer-role \
  --assume-role-policy-document file://trust-policy.json

# Annotate service account
oc annotate sa sigstore-signer -n sigstore-a2a \
  eks.amazonaws.com/role-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:role/sigstore-signer-role
```

## Running Pipelines

### Using tkn CLI

```bash
tkn pipeline start agent-card-sign-verify-deploy \
  --param agent-card-path=agent-card.json \
  --param staging=true \
  --param deploy=false \
  --workspace name=shared-workspace,claimName=sigstore-workspace \
  --serviceaccount sigstore-pipeline \
  --showlog
```

### Using PipelineRun YAML

```yaml
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: sign-verify-
  namespace: sigstore-a2a
spec:
  pipelineRef:
    name: agent-card-sign-verify-deploy
  params:
    - name: agent-card-path
      value: agent-card.json
    - name: staging
      value: "true"
    - name: deploy
      value: "false"
  workspaces:
    - name: shared-workspace
      configMap:
        name: demo-agent-card
  taskRunTemplate:
    serviceAccountName: sigstore-pipeline
```

## Troubleshooting

### SCC Issues

If pods fail to start due to security context:

```bash
# Check which SCC is being used
oc get pod <pod-name> -o yaml | grep scc

# Add service account to appropriate SCC
oc adm policy add-scc-to-user anyuid -z sigstore-pipeline -n sigstore-a2a
```

### Network Issues

If signing fails to connect to Sigstore:

```bash
# Check network policies
oc get networkpolicy -n sigstore-a2a

# Test connectivity from a pod
oc run test --rm -it --image=curlimages/curl -- \
  curl -v https://fulcio.sigstore.dev/api/v2/configuration
```

### Pipeline Failures

```bash
# View pipeline run logs
tkn pipelinerun logs <run-name> -f

# Describe for events
oc describe pipelinerun <run-name>

# Check task run details
oc get taskrun -l tekton.dev/pipelineRun=<run-name>
```

## Tearing Down

```bash
# Remove all sigstore-a2a resources
./teardown-cluster.sh

# Or manually
./setup-cluster.sh --teardown

# Optionally delete the namespace entirely
oc delete namespace sigstore-a2a
```

## Multiple Clusters

For testing across multiple clusters:

```bash
# Cluster 1
oc login https://api.cluster1.example.com:6443
./setup-cluster.sh --namespace sigstore-test-1

# Cluster 2
oc login https://api.cluster2.example.com:6443
./setup-cluster.sh --namespace sigstore-test-2

# Tear down cluster 1
oc login https://api.cluster1.example.com:6443
./teardown-cluster.sh --namespace sigstore-test-1
```
