#ddev-generated
# ---------------------------------------------------------------------------
# ddev-claude pre-built base image.
# Published to ghcr.io/makraz/ddev-claude-base:<git-tag> by
# .github/workflows/publish-image.yml.
#
# This image bundles the runtime: debian-slim + 10 packages + the unprivileged
# `claude` user (uid 1000) + the sudoers entry + the Claude Code native binary.
# It does NOT contain init-firewall.sh (which changes with addon releases)
# or any extras (which are project-specific).
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      bash \
      sudo \
      iptables \
      ipset \
      dnsmasq \
      dnsutils \
      iproute2 \
 && rm -rf /var/lib/apt/lists/*

ARG USERNAME=claude
ARG USER_UID=1000
RUN groupadd --gid $USER_UID $USERNAME \
 && useradd  --uid $USER_UID --gid $USER_UID -m -s /bin/bash $USERNAME \
 && echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
      > /etc/sudoers.d/claude-firewall \
 && chmod 0440 /etc/sudoers.d/claude-firewall

# Install Claude Code via the official native installer at image build time.
# The exact version is whatever https://claude.ai/install.sh resolves to when
# publish-image.yml runs; that version is captured in an OCI label so
# `docker inspect` shows what's baked in.
USER claude
WORKDIR /home/claude
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/claude/.local/bin:${PATH}"

WORKDIR /var/www/html
