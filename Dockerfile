# syntax=docker/dockerfile:1
FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Tools most pipeline tasks expect, plus the Docker CLI for jobs that use a mounted host socket.
# ping is for the agent itself: its self-update script (_work/_update.sh) uses it as a sleep.
# Versions are deliberately unpinned: every rebuild should pick up the latest Ubuntu security fixes.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git iputils-ping jq unzip zip \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# uid 1000 is taken by the base image's "ubuntu" user.
RUN useradd --uid 1001 --create-home --home-dir /home/agent agent \
 && mkdir -p /azp/agent /azp/_work \
 && chown -R agent:agent /azp

ARG TARGETARCH
ARG AGENT_VERSION
ARG AGENT_SHA256_AMD64
ARG AGENT_SHA256_ARM64

LABEL org.opencontainers.image.title="Azure Pipelines agent" \
      org.opencontainers.image.description="Unofficial self-hosted Azure Pipelines agent for Linux (amd64, arm64)" \
      org.opencontainers.image.source="https://github.com/KeithMarex/azure-pipelines-agent-docker" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${AGENT_VERSION}"

WORKDIR /azp/agent

# Checksums come from the release notes (scripts/resolve-agent.sh); a build without one fails.
# installdependencies.sh is the agent's own script for the .NET runtime libraries (libicu, libssl, ...).
RUN : "${AGENT_VERSION:?build-arg AGENT_VERSION is required}" \
 && arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
 && case "${arch}" in \
      amd64) pkg_arch=x64;   sha="${AGENT_SHA256_AMD64}" ;; \
      arm64) pkg_arch=arm64; sha="${AGENT_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture: ${arch}" >&2; exit 1 ;; \
    esac \
 && : "${sha:?the AGENT_SHA256_* build-arg for ${arch} is required}" \
 && curl -fsSL --retry 5 -o /tmp/agent.tar.gz \
      "https://download.agent.dev.azure.com/agent/${AGENT_VERSION}/vsts-agent-linux-${pkg_arch}-${AGENT_VERSION}.tar.gz" \
 && echo "${sha}  /tmp/agent.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/agent.tar.gz -C /azp/agent \
 && rm /tmp/agent.tar.gz \
 && ./bin/installdependencies.sh \
 && rm -rf /var/lib/apt/lists/* \
 && chown -R agent:agent /azp/agent

COPY --chmod=0755 scripts/start.sh /azp/start.sh

ENV AZP_WORK=/azp/_work
# Numeric, so platforms that enforce runAsNonRoot can verify it ("agent").
USER 1001
ENTRYPOINT ["/azp/start.sh"]
