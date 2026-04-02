FROM ubuntu:24.04
ARG HOST_UID=1000
ENV DEBIAN_FRONTEND=noninteractive
# ANTHROPIC_API_KEY is optional — only needed for API mode (pay-per-token).
# Leave unset when using a Pro/Max subscription. See SUBSCRIPTION_MODE.md.
ENV ANTHROPIC_API_KEY=""
# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    jq \
    unzip \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    ca-certificates \
    gnupg \
    lsb-release \
    less \
    vim \
    nano \
    htop \
    tree \
    ripgrep \
    fd-find \
    && rm -rf /var/lib/apt/lists/*
# Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*
# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code
# Create non-root user with matching UID
# Ubuntu 24.04 ships with a 'ubuntu' user at UID 1000 — rename it and move its home
RUN if getent passwd ${HOST_UID} > /dev/null 2>&1; then \
        OLD_USER=$(getent passwd ${HOST_UID} | cut -d: -f1) && \
        usermod -l agent -d /home/agent -m "$OLD_USER" && \
        groupmod -n agent $(getent group ${HOST_UID} | cut -d: -f1) 2>/dev/null || true; \
    else \
        groupadd -g ${HOST_UID} agent && \
        useradd -u ${HOST_UID} -g agent -m -s /bin/bash agent; \
    fi
# Ensure home directory ownership is correct
RUN chown -R agent:agent /home/agent
# Create /workspace directory
RUN mkdir -p /workspace && chown agent:agent /workspace
WORKDIR /workspace
USER agent
CMD ["sleep", "infinity"]
