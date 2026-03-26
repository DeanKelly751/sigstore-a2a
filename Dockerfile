FROM python:3.11-slim

LABEL org.opencontainers.image.source="https://github.com/sigstore/sigstore-a2a"
LABEL org.opencontainers.image.description="sigstore-a2a: Keyless signing for A2A Agent Cards"

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install sigstore-a2a from source
WORKDIR /app
COPY . /app/

RUN pip install --no-cache-dir -e .

# Install jq for JSON parsing in scripts
RUN apt-get update && apt-get install -y --no-install-recommends jq \
    && rm -rf /var/lib/apt/lists/*

# Set up non-root user
RUN useradd -m -u 1000 sigstore
USER sigstore

ENTRYPOINT ["sigstore-a2a"]
CMD ["--help"]
