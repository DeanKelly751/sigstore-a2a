# Tekton Pipelines for sigstore-a2a

Kubernetes-native CI/CD pipelines for signing, verifying, and deploying A2A Agent Cards using Sigstore.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TEKTON PIPELINE FLOW                                │
└─────────────────────────────────────────────────────────────────────────────┘

  GitHub Push                    Manual Trigger
  (agent-card.json modified)     (tkn pipeline start)
        │                              │
        └──────────┬───────────────────┘
                   │
                   ▼
    ┌──────────────────────────┐
    │     EventListener        │
    │   (github-push trigger)  │
    └────────────┬─────────────┘
                 │
                 ▼
    ┌──────────────────────────┐
    │      PipelineRun         │
    │  agent-card-sign-verify  │
    └────────────┬─────────────┘
                 │
    ┌────────────┴────────────────────────────────────┐
    │                                                 │
    ▼                                                 │
┌───────────────┐                                     │
│ sign-agent-   │                                     │
│    card       │──┐                                  │
│               │  │  OIDC Token                      │
└───────────────┘  │  (SPIFFE/K8s SA)                 │
                   │                                  │
                   ▼                                  │
            ┌─────────────┐                           │
            │   Fulcio    │ ← Certificate             │
            └─────────────┘                           │
                   │                                  │
                   ▼                                  │
            ┌─────────────┐                           │
            │    Rekor    │ ← Transparency Log        │
            └─────────────┘                           │
                   │                                  │
                   ▼                                  │
┌───────────────┐                                     │
│ verify-agent- │                                     │
│    card       │ ← Trust Policy Check                │
└───────┬───────┘                                     │
        │                                             │
        ▼                                             │
┌───────────────┐                                     │
│ policy-check  │ ← Organizational Policies           │
│  (optional)   │   (repos, capabilities, etc.)       │
└───────┬───────┘                                     │
        │                                             │
        ├────────────────┬────────────────┐           │
        │                │                │           │
        ▼                ▼                ▼           │
┌───────────────┐ ┌───────────────┐ ┌───────────────┐ │
│ serve-agent-  │ │ publish-      │ │ notify-slack  │ │
│    card       │ │ registry      │ │               │ │
│ (K8s Deploy)  │ │ (OCI Artifact)│ │               │ │
└───────────────┘ └───────────────┘ └───────────────┘ │
        │                │                │           │
        └────────────────┴────────────────┴───────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │   Agent Card Live   │
              │ /.well-known/agent  │
              └─────────────────────┘
```

## Prerequisites

1. **Tekton Pipelines** (v0.50+)
   ```bash
   kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
   ```

2. **Tekton Triggers** (for webhook-based execution)
   ```bash
   kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
   kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
   ```

3. **Tekton Dashboard** (optional, for UI)
   ```bash
   kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
   ```

## Installation

```bash
# Install all tasks
kubectl apply -f tekton/tasks/

# Install pipelines
kubectl apply -f tekton/pipelines/

# Install triggers (optional)
kubectl apply -f tekton/triggers/
```

## Quick Start

### 1. Sign and Verify an Agent Card

```bash
# Create a workspace PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: agent-card-workspace
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# Copy your agent card to the workspace
kubectl cp demo/weather-agent-card.json \
  $(kubectl get pod -l app=workspace-pod -o name):/workspace/agent-card.json

# Start the pipeline
tkn pipeline start agent-card-sign-verify-deploy \
  --param agent-card-path=agent-card.json \
  --param staging=true \
  --param deploy=false \
  --workspace name=shared-workspace,claimName=agent-card-workspace \
  --showlog
```

### 2. Verify an External Agent Card

```bash
tkn pipeline start agent-card-verify-only \
  --param signed-card-url=https://example.com/.well-known/agent.signed.json \
  --param identity-provider=https://token.actions.githubusercontent.com \
  --param expected-repository=trusted-org/agent \
  --workspace name=shared-workspace,emptyDir="" \
  --showlog
```

### 3. Using Triggers (Webhook)

```bash
# Create webhook secret
kubectl create secret generic github-webhook-secret \
  --from-literal=webhook-secret=your-webhook-secret

# Get the EventListener URL
kubectl get eventlistener agent-card-listener -o jsonpath='{.status.address.url}'

# Configure this URL as a GitHub webhook
```

## Tasks Reference

### sign-agent-card

Signs an A2A Agent Card using Sigstore keyless signing.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `agent-card-path` | Path to unsigned agent card | `agent-card.json` |
| `output-path` | Output path for signed card | `agent-card.signed.json` |
| `repository` | Repository to bind signature to | `""` |
| `staging` | Use Sigstore staging | `false` |
| `include-provenance` | Add SLSA provenance | `true` |

**Results:**
- `signed-card-digest` - SHA256 of signed card
- `rekor-log-index` - Transparency log entry
- `signer-identity` - Identity used for signing

### verify-agent-card

Verifies a signed Agent Card against trust policies.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `signed-card-path` | Path to signed agent card | `agent-card.signed.json` |
| `identity-provider` | Required OIDC issuer | `""` |
| `expected-identity` | Required signer identity | `""` |
| `expected-repository` | Required repository | `""` |
| `expected-workflow` | Required workflow | `""` |
| `fail-on-invalid` | Fail task on invalid signature | `true` |

**Results:**
- `verification-status` - `valid` or `invalid`
- `agent-name` - Name of the agent
- `agent-version` - Version of the agent

### agent-card-policy-check

Validates against organizational policies.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `signed-card-path` | Path to signed agent card | - |
| `policy-config` | JSON policy configuration | `{}` |
| `strict-mode` | Fail on any violation | `true` |

**Policy Configuration Example:**
```json
{
  "allowedRepositories": ["myorg/*", "trusted-vendor/agents"],
  "allowedIssuers": ["https://token.actions.githubusercontent.com"],
  "forbiddenCapabilities": ["pushNotifications"],
  "maxSkillCount": 10,
  "requireProvenance": true
}
```

### serve-agent-card

Deploys agent card server to Kubernetes.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `signed-card-path` | Path to signed agent card | - |
| `deployment-name` | Deployment name | `agent-card-server` |
| `namespace` | Target namespace | `default` |
| `port` | Server port | `8080` |
| `replicas` | Replica count | `1` |

### publish-agent-card-registry

Publishes to OCI registry.

| Parameter | Description | Default |
|-----------|-------------|---------|
| `signed-card-path` | Path to signed agent card | - |
| `registry-url` | OCI registry URL | - |
| `tag` | Artifact tag | `latest` |

## Pipelines Reference

### agent-card-sign-verify-deploy

Complete lifecycle pipeline: sign → verify → deploy

```bash
tkn pipeline start agent-card-sign-verify-deploy \
  --param agent-card-path=agent-card.json \
  --param repository=myorg/myagent \
  --param staging=false \
  --param identity-provider=https://token.actions.githubusercontent.com \
  --param expected-repository=myorg/myagent \
  --param deploy=true \
  --param deployment-name=my-agent-server \
  --param namespace=agents \
  --workspace name=shared-workspace,claimName=my-pvc
```

### agent-card-verify-only

Verification-only pipeline for validating external agents.

```bash
tkn pipeline start agent-card-verify-only \
  --param signed-card-url=https://agent.example.com/.well-known/agent.signed.json \
  --param identity-provider=https://token.actions.githubusercontent.com \
  --param expected-repository=trusted/agent \
  --workspace name=shared-workspace,emptyDir=""
```

## Keyless Signing with Ambient Credentials

The pipeline uses `--use_ambient_credentials` to automatically detect OIDC tokens from the environment. **No private keys needed!**

### Supported OIDC Providers

| Provider | Identity Provider URL | Setup |
|----------|----------------------|-------|
| **Google (GKE)** | `https://accounts.google.com` | GKE Workload Identity |
| **GitHub Actions** | `https://token.actions.githubusercontent.com` | OIDC token from workflow |
| **AWS (EKS)** | `https://oidc.eks.<region>.amazonaws.com/id/<id>` | IAM Roles for Service Accounts |
| **Azure (AKS)** | `https://login.microsoftonline.com/<tenant>/v2.0` | Azure Workload Identity |
| **SPIFFE/SPIRE** | Custom trust domain | SPIRE agent |

### Option 1: GKE Workload Identity (Google OIDC)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sigstore-signer
  annotations:
    iam.gke.io/gcp-service-account: signer@YOUR_PROJECT.iam.gserviceaccount.com
```

```bash
# Bind the K8s SA to Google SA
gcloud iam service-accounts add-iam-policy-binding \
  signer@YOUR_PROJECT.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:YOUR_PROJECT.svc.id.goog[tekton-pipelines/sigstore-signer]"
```

**PipelineRun:**
```bash
tkn pipeline start agent-card-sign-verify-deploy \
  --param identity-provider=https://accounts.google.com \
  --serviceaccount sigstore-signer \
  ...
```

### Option 2: GitHub Actions OIDC

If triggering Tekton from GitHub Actions, pass the OIDC token:

```yaml
# In GitHub Actions workflow
jobs:
  sign:
    permissions:
      id-token: write  # Required for OIDC
    steps:
      - name: Get OIDC Token
        id: oidc
        run: |
          TOKEN=$(curl -sLS "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sigstore" \
            -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" | jq -r '.value')
          echo "token=$TOKEN" >> $GITHUB_OUTPUT
      
      - name: Trigger Tekton
        run: |
          # Pass token to Tekton pipeline
          tkn pipeline start agent-card-sign-verify-deploy \
            --param identity-token=${{ steps.oidc.outputs.token }} \
            --param identity-provider=https://token.actions.githubusercontent.com \
            ...
```

### Option 3: AWS EKS (IRSA)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sigstore-signer
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/sigstore-signer
```

**PipelineRun:**
```bash
tkn pipeline start agent-card-sign-verify-deploy \
  --param identity-provider=https://oidc.eks.us-west-2.amazonaws.com/id/YOUR_CLUSTER_ID \
  --serviceaccount sigstore-signer \
  ...
```

### Option 4: SPIFFE/SPIRE

```yaml
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterSPIFFEID
metadata:
  name: tekton-signer
spec:
  spiffeIDTemplate: "spiffe://example.org/tekton/signer"
  podSelector:
    matchLabels:
      tekton.dev/task: sign-agent-card
```

### How It Works

```
┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│   Tekton Task    │     │     Fulcio       │     │      Rekor       │
│  (K8s Workload)  │     │   (Sigstore CA)  │     │  (Transparency)  │
└────────┬─────────┘     └────────┬─────────┘     └────────┬─────────┘
         │                        │                        │
         │  1. Get OIDC Token     │                        │
         │  (from cloud provider) │                        │
         │◀───────────────────────│                        │
         │                        │                        │
         │  2. Exchange for cert  │                        │
         │───────────────────────▶│                        │
         │                        │                        │
         │  3. Short-lived cert   │                        │
         │  (with identity)       │                        │
         │◀───────────────────────│                        │
         │                        │                        │
         │  4. Sign agent card    │                        │
         │  (ephemeral key)       │                        │
         │                        │                        │
         │  5. Log signature      │                        │
         │────────────────────────┼───────────────────────▶│
         │                        │                        │
         │  6. Inclusion proof    │                        │
         │◀───────────────────────┼────────────────────────│
         │                        │                        │
```

**Certificate contains your identity:**
- Google: `user@gmail.com` or service account email
- GitHub: `repo:owner/repo:ref:refs/heads/main`
- AWS: IAM role ARN
- SPIFFE: `spiffe://trust-domain/workload-id`

## Monitoring & Observability

### View Pipeline Runs

```bash
# List recent runs
tkn pipelinerun list

# Get logs
tkn pipelinerun logs <run-name> -f

# Describe run
tkn pipelinerun describe <run-name>
```

### Tekton Dashboard

Access at `http://localhost:9097` after port-forwarding:
```bash
kubectl port-forward svc/tekton-dashboard 9097:9097 -n tekton-pipelines
```

## Security Considerations

1. **RBAC**: Limit who can trigger pipelines
2. **Network Policies**: Restrict egress to Sigstore services
3. **Secret Management**: Use external secrets for registry credentials
4. **Audit Logging**: Enable Tekton audit logging for compliance

## Troubleshooting

### Common Issues

**"No ambient credentials found"**
- Ensure workload identity is configured
- Check service account annotations
- Verify OIDC provider is accessible

**"Signature verification failed"**
- Check identity constraints match the signer
- Verify staging vs production environment
- Check clock skew on nodes

**"Policy check failed"**
- Review policy configuration
- Check `violations` result for details
- Try with `strict-mode=false` to see all issues
