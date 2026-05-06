#ddev-generated
# ---------------------------------------------------------------------------
# Claude Code sandbox — sidecar container for ddev.
#
# Provides a locked-down runtime for autonomous AI coding agents:
#   - Node 22 LTS + Claude Code CLI
#   - Playwright + Chromium for E2E/browser testing
#   - PHP 8.5 CLI + Composer for running project tooling (phpstan, phpunit,
#     php-cs-fixer) against the code mounted from the host
#   - iptables / ipset / dnsmasq for outbound network firewall
#
# The container starts with `sleep infinity` and does nothing until you
# run `ddev claude`, which activates the firewall and opens an interactive
# Claude Code session inside.
# ---------------------------------------------------------------------------
FROM node:22-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      # Firewall sandboxing
      iptables \
      ipset \
      dnsmasq \
      dnsutils \
      iproute2 \
      # General tooling
      ca-certificates \
      curl \
      wget \
      git \
      gnupg \
      jq \
      less \
      procps \
      sudo \
      unzip \
      zip \
      lsb-release \
      # PHP build deps
      libzip-dev \
      libicu-dev \
      libxml2-dev \
      libpng-dev \
      libjpeg-dev \
      libfreetype6-dev \
      libonig-dev \
      libxslt-dev \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# PHP 8.5 from Ondřej Surý's repo (the only reliable way to get 8.5 on
# Debian Bookworm at the moment). Only the CLI + the extensions the
# Symfony project actually uses.
# ---------------------------------------------------------------------------
RUN curl -fsSL https://packages.sury.org/php/apt.gpg \
      -o /etc/apt/trusted.gpg.d/sury-php.gpg \
 && echo "deb https://packages.sury.org/php/ bookworm main" \
      > /etc/apt/sources.list.d/sury-php.list \
 && apt-get update && apt-get install -y --no-install-recommends \
      php8.5-cli \
      php8.5-bcmath \
      php8.5-curl \
      php8.5-gd \
      php8.5-intl \
      php8.5-mbstring \
      php8.5-mysql \
      php8.5-soap \
      php8.5-xml \
      php8.5-xsl \
      php8.5-zip \
 && rm -rf /var/lib/apt/lists/* \
 && update-alternatives --set php /usr/bin/php8.5

# Composer (from the official image)
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# ---------------------------------------------------------------------------
# Node global packages:
#   - @anthropic-ai/claude-code  (the CLI)
#   - chrome-devtools-mcp        (browser testing MCP for Claude)
#   - @playwright/mcp            (Playwright MCP — drives chrome-for-testing
#                                 against https://web in the ddev network)
#
# One browser install covers everything: modern Playwright's `chromium`
# channel IS the Google Chrome-for-Testing build (same binary, same version
# pin), so @playwright/mcp's default `chrome` browser resolver also finds
# it. No need to install `chrome` (unavailable on Linux arm64 — Google
# doesn't publish a stable Chrome .deb for ARM) or `chrome-for-testing`
# separately.
#
# Browser binaries go into a SHARED path (/ms-playwright) rather than the
# per-user ~/.cache/ms-playwright/. Required because RUN steps execute as
# root but the container runs at runtime as uid 1000 (claude) — without
# this override, root installs the browser into /root/.cache/… and the
# claude user can never find it. Setting PLAYWRIGHT_BROWSERS_PATH via ENV
# (not ARG) ensures both the build-time install AND the runtime launch
# resolve the same directory.
# ---------------------------------------------------------------------------
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

RUN mkdir -p "$PLAYWRIGHT_BROWSERS_PATH" \
 && npx --yes playwright install --with-deps chromium \
 && npm install -g \
      @anthropic-ai/claude-code \
      chrome-devtools-mcp \
      @playwright/mcp \
 && chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH"

# ---------------------------------------------------------------------------
# GitHub CLI — mirrors the web container install so `gh pr create` etc.
# work from inside the sidecar too. Auth comes from GH_TOKEN forwarded in
# docker-compose.claude.yaml.
# ---------------------------------------------------------------------------
RUN mkdir -p -m 755 /etc/apt/keyrings \
 && wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Non-root user — runs the Claude Code CLI so it can't accidentally write
# to /root or escalate via local misconfigurations. Matches ddev's
# convention of running container workloads as a uid-1000 user.
# ---------------------------------------------------------------------------
ARG USERNAME=claude
ARG USER_UID=1000
# node:22-bookworm ships a pre-existing `node` user at uid/gid 1000.
# Remove it so we can claim that uid/gid for `claude`.
RUN userdel -r node 2>/dev/null || true \
 && groupadd --gid $USER_UID $USERNAME \
 && useradd --uid $USER_UID --gid $USER_UID -m -s /bin/bash $USERNAME \
 && echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
      > /etc/sudoers.d/claude-firewall \
 && chmod 0440 /etc/sudoers.d/claude-firewall

# ---------------------------------------------------------------------------
# Firewall script — copied last so edits invalidate only this layer.
# ---------------------------------------------------------------------------
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod +x /usr/local/bin/init-firewall.sh

# ---------------------------------------------------------------------------
# Persist Claude Code config across rebuilds via a named volume (mounted
# from docker-compose.claude.yaml onto /home/claude/.claude).
# ---------------------------------------------------------------------------
RUN mkdir -p /home/$USERNAME/.claude \
 && chown -R $USERNAME:$USERNAME /home/$USERNAME

WORKDIR /var/www/html
