# Sigstore A2A Signing Demo

This demo shows how to sign an A2A Agent Card using sigstore-a2a.

## Prerequisites

```bash
# From the sigstore-a2a root directory
cd /Users/dekelly/sigstore-selfhost/sigstore-a2a

# Install dependencies
uv sync --prerelease=allow
```

## The Weather Agent Card

The `weather-agent-card.json` is based on the [Kagenti operator weather agent demo](https://github.com/kagenti/kagenti-operator/tree/main/kagenti-operator/demos/agentcard-spire-signing/k8s).

It describes a Kubernetes-deployed weather service with three skills:
- **Get Current Weather** - Real-time weather conditions
- **Get Weather Forecast** - 7-day forecast
- **Weather Alerts** - Storm warnings and alerts

## Signing Options

### Option 1: Interactive OAuth (Local Development)

This opens a browser for OAuth authentication:

```bash
uv run sigstore-a2a sign demo/weather-agent-card.json \
  --output demo/weather-agent-card.signed.json \
  --staging
```

> **Note:** Use `--staging` for testing to avoid polluting production transparency logs.

### Option 2: CI/CD with Ambient Credentials (GitHub Actions)

In GitHub Actions, use ambient OIDC credentials:

```bash
sigstore-a2a sign demo/weather-agent-card.json \
  --output demo/weather-agent-card.signed.json \
  --use_ambient_credentials \
  --repository $GITHUB_REPOSITORY
```

### Option 3: With SLSA Provenance

Add supply chain provenance metadata:

```bash
sigstore-a2a sign demo/weather-agent-card.json \
  --output demo/weather-agent-card.signed.json \
  --provenance \
  --repository owner/weather-agent \
  --commit-sha $(git rev-parse HEAD)
```

## Verification

### Basic Verification

```bash
uv run sigstore-a2a verify demo/weather-agent-card.signed.json --staging
```

### Verification with Identity Constraints

```bash
# Verify it came from a specific repository
uv run sigstore-a2a verify demo/weather-agent-card.signed.json \
  --staging \
  --identity_provider https://token.actions.githubusercontent.com \
  --repository kagenti/kagenti-operator

# Verify with workflow constraint
uv run sigstore-a2a verify demo/weather-agent-card.signed.json \
  --staging \
  --identity_provider https://token.actions.githubusercontent.com \
  --repository kagenti/kagenti-operator \
  --workflow "Release"
```

## Serving the Signed Agent Card

Serve the agent card at well-known A2A discovery endpoints:

```bash
uv run sigstore-a2a serve demo/weather-agent-card.signed.json --port 8080
```

This makes the card available at:
- `http://localhost:8080/.well-known/agent.json` - The agent card
- `http://localhost:8080/.well-known/agent.signed.json` - Full signed bundle

## What Gets Signed?

When you sign an agent card, the output contains:

```json
{
  "agentCard": {
    // Original agent card content
  },
  "attestations": {
    "signatureBundle": {
      "mediaType": "application/vnd.dev.sigstore.bundle.v0.3+json",
      "verificationMaterial": {
        "certificate": "...",      // Short-lived X.509 cert with OIDC identity
        "tlogEntries": [...]       // Rekor transparency log proof
      },
      "dsseEnvelope": {
        "payload": "...",          // Base64 in-toto statement
        "payloadType": "application/vnd.in-toto+json",
        "signatures": [...]        // ECDSA signature
      }
    }
  }
}
```

## GitHub Actions Workflow Example

```yaml
name: Sign Weather Agent Card

on:
  push:
    branches: [main]
    paths:
      - 'demo/weather-agent-card.json'

permissions:
  id-token: write
  contents: read

jobs:
  sign:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      
      - name: Install uv
        run: curl -LsSf https://astral.sh/uv/install.sh | sh
      
      - name: Install sigstore-a2a
        run: uv sync --prerelease=allow
      
      - name: Sign Agent Card
        run: |
          uv run sigstore-a2a sign demo/weather-agent-card.json \
            --output demo/weather-agent-card.signed.json \
            --use_ambient_credentials \
            --repository ${{ github.repository }}
      
      - name: Verify Signature
        run: |
          uv run sigstore-a2a verify demo/weather-agent-card.signed.json \
            --identity_provider https://token.actions.githubusercontent.com \
            --repository ${{ github.repository }}
      
      - name: Upload Signed Card
        uses: actions/upload-artifact@v4
        with:
          name: signed-weather-agent-card
          path: demo/weather-agent-card.signed.json
```
