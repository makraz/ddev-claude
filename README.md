# ddev-claude

A [DDEV](https://ddev.com) add-on that adds a **sandboxed sidecar
container** for running [Claude Code](https://docs.claude.com/en/docs/claude-code/overview)
(Anthropic's AI coding CLI) with `--dangerously-skip-permissions` (YOLO
mode) safely contained behind an iptables + ipset + dnsmasq firewall.

## What you get

- A `claude` sidecar service built from `node:22-bookworm` with:
  - Claude Code CLI pre-installed
  - PHP 8.5 CLI + Composer (run your project's PHP tooling against the
    bind-mounted code)
  - Playwright + Chromium (E2E / browser automation)
  - `chrome-devtools-mcp` and `@playwright/mcp` MCP servers
  - GitHub CLI (`gh`)
- An outbound firewall (default-DROP policy) that only allows:
  - `github.com`, `api.github.com`
  - `anthropic.com`, `claude.ai`
  - `registry.npmjs.org`
  - `packagist.org`, `repo.packagist.org`
  - `storage.googleapis.com`
  - The DDEV internal network (so the agent can reach `web`, `db`, etc.)
- A `ddev claude` command that launches Claude Code in YOLO mode inside
  the firewalled sidecar, as a non-root `claude` user (uid 1000).
- Persistent Claude Code auth state via named volumes (`claude-config`,
  `claude-history`) — survives `ddev restart` and add-on rebuilds.

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

# Optional: GitHub auth for the gh CLI and the GitHub MCP
export GITHUB_PERSONAL_ACCESS_TOKEN=ghp_...

# Start / restart the DDEV stack (first build takes ~5 minutes)
ddev restart

# Launch Claude Code in YOLO mode inside the sandbox
ddev claude

# Opt out of YOLO for a single run
CLAUDE_SAFE=1 ddev claude

# Pass extra flags through to the claude CLI
ddev claude --resume
ddev claude --help
```

### Allowing additional outbound domains

Set `EXTRA_ALLOWED_DOMAINS` in your host shell (space-separated) before
`ddev start` / `ddev restart`:

```bash
export EXTRA_ALLOWED_DOMAINS="sentry.io api.stripe.com"
ddev restart
ddev claude
```

The firewall's dnsmasq resolves these on demand and adds the resulting
IPs to the allow-list ipset. You can also persist them inside the
container at `/etc/firewall/extra-domains.list` (one per line).

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
│   ddev claude ──► docker exec ──► ┌─ claude sidecar ──────────────┐  │
│                                   │  Claude Code CLI              │  │
│                                   │  PHP 8.5 / Composer           │  │
│                                   │  Playwright / Chromium        │  │
│                                   │                               │  │
│                                   │  iptables default DROP        │  │
│                                   │  ipset allowed-ipv4 (dynamic) │  │
│                                   │  ipset allowed-net (ddev net) │  │
│                                   │  dnsmasq → ipset bridge       │  │
│                                   │                               │  │
│                                   │  mounts: /var/www/html (rw)   │  │
│                                   │          /home/claude/.claude │  │
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

`init-firewall.sh` (run as root via NOPASSWD sudoers entry) sets up:

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
6. **Smoke tests** — `curl` reachability checks for github + npm +
   packagist (must succeed) and `example.com` (must fail).

## Known limitations

- **No IPv6**: dropped entirely. Extend `init-firewall.sh` to
  dual-stack the allow-list if needed.
- **DNS open on port 53**: required for dnsmasq upstreams; a determined
  agent could in theory use DNS tunneling for exfiltration. If that's
  in your threat model, restrict port 53 to the host gateway only.
- **`.git` and `.env*` are bind-mounted**: the agent can read (and
  potentially commit) anything in your project directory. Keep secrets
  out of the working tree, or use `CLAUDE_SAFE=1` for untrusted tasks.
- **UID 1000 hardcoded**: the `claude` user inside the container is
  uid 1000. If your host user uses a different uid, file ownership may
  look strange on the host. Adjust via Dockerfile build args if needed.
- **PHP 8.5 baked in**: this image is opinionated (Symfony / PHP). If
  your project doesn't need PHP, you can fork and strip the relevant
  Dockerfile lines.

## Uninstall

```bash
ddev add-on remove claude
ddev restart
```

The named volumes `claude-config` and `claude-history` are preserved so
that reinstalling the add-on later keeps your Claude Code auth. To
fully wipe them:

```bash
docker volume rm ddev-<project>_claude-config ddev-<project>_claude-history
```

## License

MIT — see [LICENSE](LICENSE).
