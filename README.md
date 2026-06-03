# ddev-claude

A [DDEV](https://ddev.com) add-on that adds a **sandboxed sidecar
container** for running [Claude Code](https://docs.claude.com/en/docs/claude-code/overview)
(Anthropic's AI coding CLI) with `--dangerously-skip-permissions` (YOLO
mode) safely contained behind an iptables + ipset + dnsmasq firewall.

The default sidecar is **minimum viable**: Claude Code + firewall, on
`debian:bookworm-slim`. Anything project-specific (PHP, gh, etc.) is
added through a small opt-in extras catalog.

## What you get (default)

- A `claude` sidecar built from `debian:bookworm-slim` with:
  - Claude Code CLI (native binary, installed via Anthropic's official
    installer — no Node.js dependency)
  - git, bash, sudo, curl, ca-certificates
  - iptables/ipset/dnsmasq/dnsutils/iproute2 for the firewall
- An **outbound firewall** (default-DROP policy) that only allows:
  - `github.com`, `api.github.com`
  - `anthropic.com`, `claude.ai`
  - The DDEV internal network (so the agent can reach `web`, `db`, …)
- A `ddev claude` host command with subcommands (`safe`, `shell`,
  `exec`, `rebuild`, `help`).
- Persistent Claude Code auth + settings at `.ddev/.claude/` (gitignored).

## Adding extras

To add tooling your project needs, edit `.ddev/claude.yaml`:

```yaml
# Available extras: php
extras:
  - php

# Additional outbound domains the runtime firewall should allow.
extra_allowed_domains:
  - sentry.io
  - api.stripe.com
```

Run `ddev claude rebuild` (or `ddev restart`) to regenerate the
Dockerfile. The new image is built on the next `ddev start`.

**Currently shipped extras:** `php` (PHP 8.5 CLI + Composer + common
extensions; adds `packagist.org` + `repo.packagist.org` to the
runtime allow-list).

For anything not in the catalog, use the escape hatch (see **Cookbook**
below).

## Why this exists

Running AI coding agents autonomously is productive — until the agent
hallucinates a `curl | sh` against a compromised server, or an
adversarial prompt talks it into exfiltrating your `.env` file. This
add-on removes those risks by constraining the agent's network reach at
the kernel level (iptables default-DROP) while still letting it fetch
dependencies from the usual package registries.

With the firewall active, `--dangerously-skip-permissions` becomes safe
enough for routine use: the worst the agent can do is corrupt your
working tree, and `git reset --hard` recovers from that.

## Installation

```bash
ddev add-on get makraz/ddev-claude
ddev restart
```

Or from a local checkout (development):

```bash
ddev add-on get /path/to/ddev-claude
ddev restart
```

## Usage

```bash
# Export your Anthropic API key (or use OAuth login on first run)
export ANTHROPIC_API_KEY=sk-ant-...

# Optional: GitHub auth (for git push, gh CLI when added as an extra)
export GITHUB_PERSONAL_ACCESS_TOKEN=ghp_...

# (optional) edit .ddev/claude.yaml to opt into extras
# Then start / restart the DDEV stack
ddev restart

# Launch Claude Code in YOLO mode inside the sandbox
ddev claude

# Subcommands
ddev claude safe              # without --dangerously-skip-permissions
ddev claude shell             # bash inside the sidecar (firewall active)
ddev claude exec composer install   # run a single command (one-shot)
ddev claude rebuild           # regenerate Dockerfile after editing claude.yaml
ddev claude help              # show this list

# Pass-through to the claude CLI
ddev claude --resume
ddev claude -p "summarize this repo"
```

`CLAUDE_SAFE=1 ddev claude` is still honored for back-compat.

## Cookbook (escape hatch)

For tooling not in the catalog, drop fragments into `.ddev/claude.local/`:

### Add the GitHub CLI

`.ddev/claude.local/Dockerfile.fragment`:
```dockerfile
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      gnupg lsb-release \
 && mkdir -p -m 755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*
```

(No `.ddev/claude.local/extra-domains.list` entry needed — `github.com` is in
the default allow-list.)

### Add Node.js + npm (for npm-based MCPs)

`.ddev/claude.local/Dockerfile.fragment`:
```dockerfile
USER root
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*
```

`.ddev/claude.local/extra-domains.list`:
```
deb.nodesource.com
registry.npmjs.org
```

### Add Playwright + Chromium

`.ddev/claude.local/Dockerfile.fragment`:
```dockerfile
USER root
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN mkdir -p "$PLAYWRIGHT_BROWSERS_PATH" \
 && npx --yes playwright install --with-deps chromium \
 && npm install -g @playwright/mcp chrome-devtools-mcp \
 && chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH"
```

`.ddev/claude.local/extra-domains.list`:
```
storage.googleapis.com
```

(Requires the Node.js fragment above to be present first.)

## Verifying the sandbox

After `ddev claude` starts, run a smoke test inside the session:

```
Please run:
  curl -sS --max-time 5 https://api.github.com           # should succeed
  curl -sS --max-time 3 https://example.com || echo BLOCKED  # should be BLOCKED
  sudo iptables -L OUTPUT -n | head -1                   # should say "policy DROP"
```

If `example.com` is reachable or the iptables policy is `ACCEPT`, the
firewall is not active — stop and investigate before trusting the agent
with autonomous work.

## Architecture

```
┌─ Host ───────────────────────────────────────────────────────────────┐
│                                                                      │
│   .ddev/claude.yaml ──► build-image.sh ──► .ddev/claude/Dockerfile   │
│                          (pre-start hook)                             │
│                                                                      │
│   ddev claude ──► docker exec ──► ┌─ claude sidecar ──────────────┐  │
│                                   │  Claude Code CLI (native)     │  │
│                                   │  + selected extras (e.g. php) │  │
│                                   │                               │  │
│                                   │  iptables default DROP        │  │
│                                   │  ipset allowed-ipv4 (dynamic) │  │
│                                   │  ipset allowed-net (ddev net) │  │
│                                   │  dnsmasq → ipset bridge       │  │
│                                   │                               │  │
│                                   │  mounts: /var/www/html (rw)   │  │
│                                   │          /home/claude/.claude │  │
│                                   │            ← .ddev/.claude/   │  │
│                                   └──────────┬────────────────────┘  │
│                                              │ ddev default network  │
│              ┌───────────────────────────────┼──────────────────┐    │
│              ▼                               ▼                  ▼    │
│        ┌─ web ──┐                    ┌─ db ────┐         ┌─ other─┐  │
│        │ nginx  │                    │ mariadb │         │  ddev  │  │
│        │ php-fpm│                    │         │         │svcs... │  │
│        └────────┘                    └─────────┘         └────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

## How the firewall works

`init-firewall.sh` (run as root via a NOPASSWD sudoers entry) sets up:

1. **ipsets** — `allowed-ipv4` (hash:ip) and `allowed-net` (hash:net).
2. **Initial DNS resolution** — `dig` resolves the default + extra
   domains, populating `allowed-ipv4`.
3. **dnsmasq** — listens on `127.0.0.1`, upstreams to `127.0.0.11`
   (Docker's embedded DNS — keeps DDEV service names like `web`/`db`
   resolvable), `1.1.1.1`, `8.8.8.8`. Each allow-listed domain is bound
   via `ipset=/<domain>/allowed-ipv4`, so any future resolution
   automatically extends the allow-list — handles CDN IP rotation.
4. **iptables** — default policy DROP on INPUT/OUTPUT/FORWARD. ACCEPT
   only loopback, established/related, DNS (port 53), the two ipsets,
   the host gateway, and inbound 80/443.
5. **IPv6** — dropped entirely.
6. **Smoke tests** — `curl` reachability checks for github (must
   succeed) and `example.com` (must fail).

## Known limitations

- **No IPv6**: dropped entirely. Extend `init-firewall.sh` to
  dual-stack the allow-list if needed.
- **DNS open on port 53**: required for dnsmasq upstreams; a determined
  agent could in theory use DNS tunneling for exfiltration.
- **`.git` and `.env*` are bind-mounted**: the agent can read (and
  potentially commit) anything in your project directory. Keep secrets
  out of the working tree, or use `CLAUDE_SAFE=1` for untrusted tasks.
- **UID 1000 hardcoded**: the `claude` user inside the container is
  uid 1000. If your host user uses a different uid, file ownership may
  look strange on `.ddev/.claude/`. Adjust via Dockerfile build args if needed.
- **`.ddev/.claude/` holds auth state**: a determined agent could plant
  configuration there (e.g., a malicious MCP entry in
  `~/.claude/settings.json`) that runs in the next session. Such code
  still runs under the same firewall + uid, so it cannot break out, but
  the persistence vector is real.

## Uninstall

```bash
ddev add-on remove claude
ddev restart
```

Addon-managed files are removed. Preserved (delete manually if
desired):

```bash
rm -rf .ddev/claude.yaml .ddev/.claude/ .ddev/claude.local/
```

## License

MIT — see [LICENSE](LICENSE).
