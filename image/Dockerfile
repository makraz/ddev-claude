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

# Install Claude Code via the official native installer, pinned to an EXPLICIT
# version.
#
# Why pinned rather than `stable`: without a pin the content of this image
# depends on when the build ran, so the same git tag produces different
# artifacts and a past release cannot be reconstructed. Worse, in a multi-arch
# build the amd64 and arm64 layers run this step independently — an upstream
# release landing mid-build would put two different agent versions in one
# manifest. publish-image.yml resolves the version once and passes it here, so
# the OCI label and the actual contents agree by construction.
#
# The installer itself verifies the downloaded binary against a SHA256 checksum
# from its own manifest, so the download is integrity-checked upstream; the pin
# is about determinism, not about the download being unchecked.
ARG CLAUDE_VERSION=stable
USER claude
WORKDIR /home/claude
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_VERSION}" \
 && installed="$(/home/claude/.local/bin/claude --version | awk '{print $1}')" \
 && case "${CLAUDE_VERSION}" in \
      stable|latest) echo "note: unpinned build, resolved to ${installed}" ;; \
      *) [ "${installed}" = "${CLAUDE_VERSION}" ] || { \
           echo "ERROR: asked for ${CLAUDE_VERSION}, installer produced ${installed}" >&2; \
           exit 1; } ;; \
    esac \
 && printf '%s\n' "${installed}" > /home/claude/.claude-code-version
ENV PATH="/home/claude/.local/bin:${PATH}"

WORKDIR /var/www/html
