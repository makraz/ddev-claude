# DDEV Claude

[![add-on registry](https://img.shields.io/badge/DDEV-Add--on_Registry-blue)](https://addons.ddev.com)
[![tests](https://github.com/makraz/ddev-claude/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/makraz/ddev-claude/actions/workflows/tests.yml?query=branch%3Amain)
[![last commit](https://img.shields.io/github/last-commit/makraz/ddev-claude)](https://github.com/makraz/ddev-claude/commits)
[![release](https://img.shields.io/github/v/release/makraz/ddev-claude)](https://github.com/makraz/ddev-claude/releases/latest)

## Overview

This add-on integrates [Claude Code](https://docs.claude.com/en/docs/claude-code/overview), Anthropic's AI coding CLI, into your [DDEV](https://ddev.com) project as a **sandboxed sidecar container**. Claude runs with `--dangerously-skip-permissions` (YOLO mode) safely contained behind an iptables + ipset + dnsmasq firewall, so an agent off the rails cannot exfiltrate your `.env`, your SSH keys, or anything else outside the project tree.

The default sidecar is **minimum viable**: Claude Code + firewall on a pre-built `debian:bookworm-slim` base image. Project-specific tools (PHP, gh, Playwright, etc.) are opt-in via a small extras catalog or a Dockerfile escape hatch.

## Installation

```bash
ddev add-on get makraz/ddev-claude
ddev restart
```

To pin to a specific version (see [Releases](https://github.com/makraz/ddev-claude/releases) for what's available):

```bash
ddev add-on get makraz/ddev-claude@v0.2.0
ddev restart
```

After `ddev add-on get`, commit the changes to your project's `.ddev/` directory.

## Usage

| Command | Description |
| --- | --- |
| `ddev claude` | Interactive Claude Code session (YOLO mode, default). |
| `ddev claude safe` | Same, but **without** `--dangerously-skip-permissions`. |
| `ddev claude shell` | Drop into bash inside the sidecar (firewall active). |
| `ddev claude exec <cmd>` | Run one command in the sidecar non-interactively. |
| `ddev claude rebuild` | Regenerate `.ddev/claude/Dockerfile` after editing `.ddev/claude.yaml`. |
| `ddev claude help` | Print the help text. |
| `ddev claude <args>` | Anything else passes through to the `claude` CLI (e.g. `--resume`). |

The sidecar is reachable as the `claude` service on the DDEV default network. Auth tokens and settings persist at `.ddev/.claude/` (gitignored by default).

### Environment variables

Set on your host shell before `ddev start` / `ddev restart`. The sidecar's `docker-compose.claude.yaml` forwards them into the container.

| Variable | Default | Description |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | _unset_ | API key. Optional — OAuth flow runs on first launch if unset. |
| `GITHUB_PERSONAL_ACCESS_TOKEN` | _unset_ | Forwarded to the sidecar so the agent can `git push` to private repos. Also exported as `GH_TOKEN` for `gh` and GitHub MCP fragments added via the escape hatch. |
| `EXTRA_ALLOWED_DOMAINS` | _unset_ | Space-separated extra outbound domains. Consumed once, at container start, so set it **before** `ddev start` / `ddev restart` (it is persisted to a root-owned allow-list inside the container; the running agent cannot change it). Prefer `.ddev/claude.yaml`'s `extra_allowed_domains:` for project-level settings. |
| `PLAYWRIGHT_BASE_URL` | `https://web` | Pre-set inside the container so Playwright/MCP fragments added via the escape hatch hit the DDEV `web` service by default. Override on the host shell if needed. |
| `CLAUDE_SAFE` | `0` | Read by the `ddev claude` host command. Set to `1` to opt out of YOLO mode for a single invocation (equivalent to `ddev claude safe`). |

## Performance

When Mutagen is enabled the sidecar reads the project through DDEV's synced
Docker volume rather than a host bind mount — roughly 20× faster on
content-heavy operations like a `grep` over `vendor/`. See
[docs/PERFORMANCE.md](docs/PERFORMANCE.md) for the measurements and how to
reproduce them.

`ddev claude` refuses to start while the Mutagen sync is still staging, because
an agent pointed at a half-synced tree reports that your files do not exist.

## Configuration

`.ddev/claude.yaml` accepts five keys. Block-style lists only; `extras: [php]`
is a parse error.

| Key                     | Type   | Default                                              |
| ----------------------- | ------ | ---------------------------------------------------- |
| `extras`                | list   | none — available: `php`, `python`, `node`             |
| `extra_allowed_domains` | list   | none                                                  |
| `tools`                 | list   | `Read`, `Write`, `Bash`, `Skill`                      |
| `plugins`               | list   | `superpowers`, `code-review`, `gitlab`, `code-simplifier` |
| `mount_mode`            | scalar | `auto` — also `mutagen`, `bind`                       |

`tools` is an allow-list over Claude Code's built-in tool set. The default
deliberately excludes `Edit`, `Grep`, `Glob`, `Task`, `WebFetch`, `WebSearch`,
`NotebookEdit`, `TodoWrite` and `SlashCommand`, and all MCP tools. `Skill` is
included because `superpowers` is enabled by default and exists to be invoked
through it.

Dropping `Edit` has a real cost: every change becomes a whole-file `Write`,
which spends output tokens proportional to file size and risks losing unrelated
content in large files. Add `Edit` back if that trade is wrong for your project.
Add `Edit` to the `tools:` list in `.ddev/claude.yaml`, then `ddev claude rebuild && ddev restart`.

`tools` and `plugins` are baked into the image at root-owned paths, so the agent
cannot widen them at runtime. Changing either needs:

```bash
ddev claude rebuild && ddev restart
```

### Available extras

| Extra | What it installs | Adds to firewall allow-list |
| --- | --- | --- |
| `php` | PHP 8.5 CLI + Composer + common extensions (bcmath, curl, gd, intl, mbstring, mysql, soap, xml, xsl, zip) via Ondřej Surý's apt repo. | `packagist.org`, `repo.packagist.org` |
| `python` | CPython 3 (`python3`, `python3-venv`, `python3-pip`) from Debian's own repo, for Python-backed Claude Code plugins (e.g. `remember`, `security-guidance`). No third-party apt repo, so no additional signing key to pin and trust, unlike the `php` extra which must trust Sury. | `pypi.org`, `files.pythonhosted.org` |
| `node` | Node.js and npm from Debian bookworm (Node 18.x), for Node-backed Claude Code plugins (e.g. `php-lsp`, `skill-creator`). Debian's own packages, for the same reason as `python`: no third-party NodeSource key to pin and trust. | `registry.npmjs.org` |

Edit `.ddev/claude.yaml`, run `ddev claude rebuild` (or `ddev restart`), and the image is regenerated.

## Advanced Customization

For tooling not in the catalog, drop fragments into `.ddev/claude.local/`:

### GitHub CLI

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

(`github.com` is already in the default allow-list — no `extra-domains.list` entry needed.)

### Node.js + npm (for npm-based MCPs)

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

### Playwright + Chromium

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

(Requires the Node.js fragment first.)

## Components

A `claude` sidecar built from a pre-built multi-arch base image (`ghcr.io/makraz/ddev-claude-base:<version>`, published from this repo) containing:

- Claude Code CLI (native binary, installed at image build time and version-pinned per release).
- `git`, `bash`, `sudo`, `curl`, `ca-certificates`.
- `iptables`, `ipset`, `dnsmasq`, `dnsutils`, `iproute2` for the firewall stack.
- The unprivileged `claude` user (uid 1000) with a NOPASSWD sudoers entry scoped to `/usr/local/bin/init-firewall.sh`.

An outbound firewall (default-DROP policy) that allows only:

- `github.com`, `api.github.com`
- `anthropic.com`, `claude.ai`, `downloads.claude.ai` (the latter so `claude update` works)
- The DDEV internal network (so the agent can reach `web`, `db`, sibling add-ons).
- Whatever each enabled extra contributes (`.domains` files) and your `.ddev/claude.yaml` adds via `extra_allowed_domains`.

The image tag is pinned to the addon version 1:1. Installing `ddev-claude@<tag>` always pulls `ddev-claude-base:<tag>` — no floating `:latest`. The exact Claude Code build baked into a given image is recorded in the OCI label `io.makraz.ddev-claude.claude-version` and visible via `docker inspect`.

## Verifying the sandbox

After `ddev claude` starts, run a smoke test inside the session:

```
curl -sS --max-time 5 https://api.github.com           # should succeed
curl -sS --max-time 3 https://example.com || echo BLOCKED  # should be BLOCKED
sudo iptables -L OUTPUT -n | head -1                   # should say "policy DROP"
```

If `example.com` is reachable or the iptables policy is `ACCEPT`, the firewall is not active — stop and investigate before trusting the agent with autonomous work.

## How the firewall works

The firewall is activated **at container start** by `entrypoint.sh` (PID 1, running as root), so every way into the container — `ddev claude`, `ddev claude shell`, `ddev exec -s claude`, and direct `docker exec` — is sandboxed, not just the `ddev claude` host command. `ddev claude` re-asserts it (idempotently) as a safety net.

`init-firewall.sh` sets up:

1. **ipsets** — `allowed-ipv4` (hash:ip) and `allowed-net` (hash:net).
2. **Initial DNS resolution** — `dig` resolves the default + extra domains, populating `allowed-ipv4`.
3. **dnsmasq** — listens on `127.0.0.1`, upstreams to `127.0.0.11` (Docker's embedded DNS, so DDEV service names like `web`/`db` resolve), `1.1.1.1`, `8.8.8.8`. Each allow-listed domain is bound via `ipset=/<domain>/allowed-ipv4`, so future resolutions automatically extend the allow-list — handles CDN IP rotation.
4. **iptables** — default policy DROP on INPUT/OUTPUT/FORWARD. ACCEPT only loopback, established/related, DNS (port 53), the two ipsets, the host gateway, and inbound 80/443.
5. **IPv6** — dropped entirely via `ip6tables`. If `ip6tables` is unavailable but the container has an IPv6 default route, `init-firewall.sh` **fails loudly** rather than leave v6 egress unfiltered.
6. **Smoke tests** — reachability checks for github (must succeed) and `example.com` (must fail).

The outbound allow-list is read **only from root-owned files** (`/etc/claude-firewall/extra-domains.list`, baked into the image from `.ddev/claude.yaml` at build; and `/etc/claude-firewall/runtime-domains.list`, written from `EXTRA_ALLOWED_DOMAINS` at start). Both live outside the bind-mounted project tree, and the script ignores its own environment, so the unprivileged agent cannot widen its egress by editing a file or re-running the firewall via `sudo`. Changing the `.ddev/claude.yaml` domains therefore requires `ddev claude rebuild` + `ddev restart`.

> **The firewall bounds _where_ traffic goes, not _what_ leaves through allowed hosts.** The default allow-list includes GitHub, and the sidecar holds the agent's `GH_TOKEN`/`GITHUB_PERSONAL_ACCESS_TOKEN` — so a determined or compromised agent can still exfiltrate over an allowed channel (e.g. push a repo or gist). Treat it as a guard against *accidental* egress, not a barrier against a determined exfiltrator; keep the allow-list and your token scopes narrow. See [SECURITY.md](SECURITY.md#what-the-firewall-does-not-protect-against) for the full limitations.

## Developing the addon

The published image (`ghcr.io/makraz/ddev-claude-base:<version>`) is built from `image/Dockerfile` by `.github/workflows/publish-image.yml` on every git tag push. To iterate on `image/Dockerfile` without publishing:

```bash
# Build locally with the tag the addon expects:
TAG=$(grep -m1 'FROM ghcr.io/.*/ddev-claude-base:' .ddev/claude/Dockerfile.base | sed 's|.*:||')
docker build -t "ghcr.io/makraz/ddev-claude-base:${TAG}" image/

# ddev restart picks up the local image (Docker's default `missing`
# pull policy uses local images when present).
ddev restart
```

To cut a release:

```bash
git tag v0.3.0-beta.1            # or v0.3.0 for stable
git push origin v0.3.0-beta.1
# publish-image.yml builds + pushes the image to GHCR (~5 min, multi-arch).

gh release create v0.3.0-beta.1 --prerelease --notes-file release-notes.md
```

## Known limitations

- **No IPv6**: dropped entirely. Extend `init-firewall.sh` if dual-stack is required.
- **DNS open on port 53**: required for dnsmasq upstreams; a determined agent could in theory use DNS tunneling for exfiltration.
- **`.git` and `.env*` are bind-mounted**: the agent can read (and potentially commit) anything in your project directory. Keep secrets out of the working tree, or use `CLAUDE_SAFE=1` for untrusted tasks.
- **UID 1000 hardcoded**: the `claude` user inside the container is uid 1000. If your host user uses a different uid, file ownership may look unusual on `.ddev/.claude/`.
- **`.ddev/.claude/` holds auth state**: a determined agent could plant configuration there (e.g. a malicious MCP entry in `~/.claude/settings.json`) that runs in the next session. Such code still runs under the same firewall + uid, so it cannot break out, but the persistence vector is real.

## Removing

```bash
ddev add-on remove claude
ddev restart
```

Add-on-managed files are removed. User-managed files are preserved (delete manually if desired):

```bash
rm -rf .ddev/claude.yaml .ddev/.claude/ .ddev/claude.local/
```

## Credits

**Contributed and maintained by [@makraz](https://github.com/makraz)**

Firewall sandboxing approach inspired by Anthropic's official Claude Code devcontainer reference.
