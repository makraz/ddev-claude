# Minimum Viable ddev-claude Design

**Status:** Approved (brainstorming) — pending user spec review
**Date:** 2026-05-19
**Author:** brainstorming session with @hamza

---

## Goal

Strip the `ddev-claude` add-on to a minimum-viable core (Claude Code + firewall) and make the three known ergonomic pain points materially better:

1. **First build is too slow** — today's image is `node:22-bookworm` plus PHP/Composer/Playwright/Chromium/MCPs/gh, totalling ~1.5GB and ~5 minutes on a cold cache.
2. **Adding tools is painful** — extending the sidecar today requires editing the addon's Dockerfile and rebuilding.
3. **`ddev claude` CLI UX** — `CLAUDE_SAFE=1 ddev claude` is awkward; the command has no subcommand structure.

Non-goals:
- Re-architecting how the agent reaches sibling DDEV services. The current model (bind-mount + run-in-sidecar) is kept unchanged.
- Adding docker.sock mounting, SSH bridges into `web`, or any other cross-container exec primitive.

## Hard constraints (security model)

These properties hold today and **must** continue to hold after the redesign:

- **Outbound network isolation.** iptables default-DROP on INPUT/OUTPUT/FORWARD; only the dnsmasq-populated `allowed-ipv4` ipset, the docker subnet ipset, loopback, ESTABLISHED/RELATED, DNS, ICMP echo, and the host gateway pass. This mirrors Anthropic's devcontainer reference firewall approach.
- **Filesystem isolation.** The agent has read/write access to (a) the project bind-mount at `/var/www/html`, (b) its own `~/.claude` config dir, and (c) `/tmp` inside the ephemeral container layer. It cannot read host SSH keys, host AWS creds, host Keychain, sibling-container filesystems, or anything outside the project tree.
- **No privileged escape.** Agent runs as uid 1000 (non-root). The single sudoers entry is `NOPASSWD: /usr/local/bin/init-firewall.sh` — nothing else. `apt-get install`, `chmod 4755`, etc. require root and fail.

Build-time installs (when the image is constructed by `docker build` on the host) happen **before** the runtime firewall is active. Adding `php` does not force `packages.sury.org` onto the runtime allow-list — that fetch happens during the build, with the host's normal network. The runtime allow-list only expands for domains an extra explicitly needs *at runtime* (e.g., `composer install` later in a session needs `packagist.org`).

## Architecture overview

The addon ships a **minimal core** image. Project-specific tooling is added via an **opt-in extras catalog**. A per-project config file (`.ddev/claude.yaml`) lists which extras the project wants. At image-build time, a host-side script (`build-image.sh`) stitches the base Dockerfile together with the requested extra fragments plus an optional project-local fragment.

```
┌─ project (.ddev/claude.yaml) ──────────────────┐
│  extras: [php]                                 │
│  extra_allowed_domains: [sentry.io]            │
└──────────────────┬─────────────────────────────┘
                   │ read by build-image.sh, run on pre-start-host hook
                   ▼
┌─ addon (claude/) ──────────────────────────────┐
│  Dockerfile.base       lean default            │
│  build-image.sh        assembles per project   │
│  init-firewall.sh      reads runtime allow-list│
│  extras/php.fragment   Dockerfile snippet      │
│  extras/php.domains    runtime allow-list adds │
└──────────────────┬─────────────────────────────┘
                   │ produces .ddev/claude/Dockerfile
                   │           .ddev/claude/extra-domains.list
                   ▼
┌─ runtime (sidecar container) ──────────────────┐
│  claude binary, git, firewall stack, +         │
│  selected extras. Firewall allow-list =        │
│  defaults ∪ extras' contributions ∪            │
│  project extra_allowed_domains ∪ escape hatch. │
└────────────────────────────────────────────────┘
```

The bind-mount (`../:/var/www/html`), the non-root `claude` user (uid 1000), the `ddev claude` host command, and the firewall design are all retained. What changes is (a) the *contents* of the sidecar image, and (b) the addition of a build-time config-driven assembly step.

## Components

### Default image (`claude/Dockerfile.base`)

Base swaps from `node:22-bookworm` (~400MB) to `debian:bookworm-slim` (~30MB). Claude Code is installed via Anthropic's official native installer (`curl -fsSL https://claude.ai/install.sh | bash`) as the unprivileged `claude` user — no Node.js dependency.

```dockerfile
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

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod 0755 /usr/local/bin/init-firewall.sh

# ---- EXTRAS INJECTION POINT ----
# build-image.sh concatenates each selected extras/<name>.fragment here,
# followed by .ddev/claude.local/Dockerfile.fragment (if present).
# {{EXTRAS}}
# --------------------------------

USER claude
WORKDIR /home/claude
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/claude/.local/bin:${PATH}"

WORKDIR /var/www/html
```

**Removed from today's Dockerfile:**
- Base image `node:22-bookworm` and its Node 22 runtime, npm cache, `node` user.
- All PHP packages, PHP build deps (`libzip-dev`, `libicu-dev`, `libxml2-dev`, `libpng-dev`, `libjpeg-dev`, `libfreetype6-dev`, `libonig-dev`, `libxslt-dev`), Composer install layer, sury apt repo wiring.
- Playwright + Chromium install layer (`PLAYWRIGHT_BROWSERS_PATH`, `npx playwright install`).
- `@anthropic-ai/claude-code`, `chrome-devtools-mcp`, `@playwright/mcp` npm globals.
- GitHub CLI install (apt repo + `gh` package).
- Convenience packages dropped from defaults: `gnupg`, `wget`, `jq`, `less`, `procps`, `unzip`, `zip`, `lsb-release`. (Extras that need them install them.)

**Build cache ordering:** core packages → user creation → firewall script → extras → claude install. When the extras list changes, only the claude install layer is invalidated. When the firewall script changes, only firewall + extras + claude invalidate.

**Trade-off note:** `curl https://claude.ai/install.sh | bash` is a remote-piped-to-bash install. Accepted because (a) it's Anthropic's recommended path per their docs, (b) we already trust `claude.ai` for everything else, (c) it removes the entire Node.js layer. If Anthropic publishes a stable apt repo or a checksummed tarball URL, switch to that.

### Per-project config (`.ddev/claude.yaml`)

User-editable. Tiny schema:

```yaml
# Available extras: php
extras:
  - php

# Additional outbound domains the runtime firewall should allow.
extra_allowed_domains:
  - sentry.io
  - api.stripe.com
```

If the file is absent or both lists are empty, the sidecar is built with zero extras (minimum viable). Parser is a small awk block in `build-image.sh`, tolerant of comments, blank lines, and the two top-level list keys. Anything else aborts with a clear error (`unknown key 'foo' in .ddev/claude.yaml`). No `yq`, `python`, or other host parser dependency.

### Extras catalog (`claude/extras/`)

Initial catalog ships **one** entry: `php`. Files:

- `claude/extras/php.fragment` — Dockerfile fragment installing PHP 8.5 CLI + Composer + the extensions the current Dockerfile installs (`bcmath`, `curl`, `gd`, `intl`, `mbstring`, `mysql`, `soap`, `xml`, `xsl`, `zip`), via Ondřej Surý's apt repo. Build deps (`libzip-dev`, `libicu-dev`, …) are installed and then removed at the end of the fragment to keep the layer size down.
- `claude/extras/php.domains` — contents: `packagist.org`, `repo.packagist.org`. These get added to the runtime firewall allow-list when the `php` extra is selected.

No `php.requires` file (PHP has no extras-level dependencies).

The `.requires` mechanism is implemented in `build-image.sh` for future catalog growth (e.g., a future `playwright` extra would `.requires` a `node` extra), but it's not exercised by the initial catalog.

**Everything else** (node + npm-based MCPs, gh CLI, Playwright + Chromium, sqlite-cli, anything else) is handled via the escape hatch (below). The README ships a "Cookbook" section with copy-pasteable `Dockerfile.fragment` examples for the common cases.

### Escape hatch (`.ddev/claude.local/`)

For anything not in the catalog:

- `.ddev/claude.local/Dockerfile.fragment` — appended at the `{{EXTRAS}}` injection point, after any selected catalog fragments. Free-form Dockerfile syntax. User's responsibility.
- `.ddev/claude.local/extra-domains.list` — one domain per line, appended to the runtime allow-list.

`.ddev/claude.local/` is gitignored by default (auto-added on install). If users want to share these across the team, they remove the gitignore entry themselves.

### Build pipeline (`claude/build-image.sh`)

Runs on the host at `pre-start-host`, registered via `.ddev/config.claude.yaml`'s `hooks:` block (which the addon ships at install time). Sequence:

1. Read `.ddev/claude.yaml` if present, else default to empty extras list.
2. Validate each extra name — `claude/extras/<name>.fragment` must exist. Unknown name → error and abort.
3. Topologically resolve `.requires` chains.
4. Compute a hash of (resolved extras list, contents of each fragment, contents of `.ddev/claude.local/Dockerfile.fragment`, contents of every selected `.domains` file, project's `extra_allowed_domains` list, `.ddev/claude.local/extra-domains.list`). Compare to `.ddev/claude/.build-stamp`. If unchanged, exit 0 silently.
5. Generate `.ddev/claude/Dockerfile`. The literal line `# {{EXTRAS}}` in `Dockerfile.base` is the cut point (the surrounding `# ---- EXTRAS INJECTION POINT ----` / `# --------------------------------` decorative comments are part of the base and are preserved on both sides). Layout:
   ```
   <Dockerfile.base contents, up to and including the line "# ---- EXTRAS INJECTION POINT ----">
   <Dockerfile.base content line "# build-image.sh concatenates each selected ...">
   <Dockerfile.base content line "# followed by .ddev/claude.local/Dockerfile.fragment (if present).">
   <-- cut here, REPLACING the literal "# {{EXTRAS}}" line -->
   <selected fragments, in dependency order, separated by blank lines>
   <.ddev/claude.local/Dockerfile.fragment, if present>
   <-- resume base -->
   <Dockerfile.base content line "# --------------------------------" and everything below it (USER claude / WORKDIR / curl install / PATH / final WORKDIR)>
   ```
   Concretely, `build-image.sh` does `sed '/# {{EXTRAS}}/r /dev/stdin' Dockerfile.base | sed '/# {{EXTRAS}}/d'` or equivalent, where stdin is the concatenation of selected fragments + the project's local fragment.

   **Fragment USER convention:** When the `{{EXTRAS}}` marker is hit in `Dockerfile.base`, the current Docker layer state is `USER root` (carried over from `RUN chmod 0755 /usr/local/bin/init-firewall.sh`). Fragments execute as root by default. If a fragment changes USER for any reason, it must restore `USER root` before its end. The base then switches to `USER claude` immediately after the injection block.
6. Generate `.ddev/claude/extra-domains.list`:
   ```
   <every selected extra's .domains file, deduped>
   <.ddev/claude.local/extra-domains.list, if present>
   <one line per entry in extra_allowed_domains from .ddev/claude.yaml>
   ```
7. Write the new hash to `.ddev/claude/.build-stamp`.

The pre-start hook ensures the Dockerfile is always in sync with `.ddev/claude.yaml` before docker-compose builds the sidecar. Users can also re-run the assembly explicitly via `ddev claude rebuild` (see CLI section).

### Firewall runtime (`claude/init-firewall.sh`)

Structure unchanged: default-DROP iptables, ipset-driven allow-list, dnsmasq → ipset bridge, smoke tests at the end. Two changes:

**Change 1 — trimmed default allow-list:**

```bash
DEFAULT_DOMAINS=(
  "github.com"
  "api.github.com"
  "anthropic.com"
  "claude.ai"
)
```

Removed from defaults: `registry.npmjs.org`, `packagist.org`, `repo.packagist.org`, `storage.googleapis.com`. They come back automatically when the relevant extra is enabled, or via the escape hatch.

**Change 2 — read the build-generated allow-list file:**

```bash
EXTRA_FILES=(
  "/var/www/html/.ddev/claude/extra-domains.list"   # build-generated
  "/etc/firewall/extra-domains.list"                # legacy fallback
)
for f in "${EXTRA_FILES[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -n "$line" ]] && EXTRA_DOMAINS+=("$line")
  done < "$f"
done

if [[ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_DOMAINS+=( ${EXTRA_ALLOWED_DOMAINS} )
fi
```

Final runtime allow-list = `DEFAULT_DOMAINS ∪ extras' .domains ∪ project extra_allowed_domains ∪ .ddev/claude.local/extra-domains.list ∪ EXTRA_ALLOWED_DOMAINS env`.

### State directory: `.ddev/.claude/`

Replaces today's named Docker volumes `claude-config` and `claude-history`. Bind-mounted into the sidecar at `/home/claude/.claude` and `/home/claude/.bash_history.d`:

```yaml
# docker-compose.claude.yaml
volumes:
  - ../:/var/www/html
  - ../.ddev/.claude:/home/claude/.claude
  - ../.ddev/.claude/bash_history.d:/home/claude/.bash_history.d
```

**Removed from the compose file:**
```yaml
volumes:
  claude-config:
  claude-history:
```
Both named-volume declarations are deleted.

**At install time, an inline `pre_install_actions` shell block in `install.yaml` (no separate script needed):**
1. `mkdir -p .ddev/.claude/bash_history.d`
2. Ensure `.ddev/.gitignore` contains `/.claude/` and `/claude.local/` (create file if absent; idempotent via `grep -qxF || echo >>`).
3. `chown 1000:1000 .ddev/.claude` if the host uid permits — silently skip otherwise (same uid-mismatch caveat the README already documents).

Note: `.ddev/.claude/` (with the leading dot) is deliberately chosen to avoid clashing with `.ddev/claude/`, which is the addon's source directory installed by `ddev add-on get`.

### Host command: `commands/host/claude`

Subcommand router. Reserved words: `safe`, `shell`, `exec`, `rebuild`, `help`. Anything else — including any flag starting with `-` — passes through to the `claude` binary unchanged.

```
ddev claude                      # interactive YOLO session (default)
ddev claude safe                 # without --dangerously-skip-permissions
ddev claude shell                # bash inside the sidecar (firewall active)
ddev claude exec <cmd> [args]    # run one command non-interactively
ddev claude rebuild              # regenerate Dockerfile from .ddev/claude.yaml
ddev claude help                 # print this list

# Pass-through (any other args go straight to the claude CLI):
ddev claude --resume
ddev claude --help               # claude's own help, not the addon's
ddev claude -p "summarize foo"
```

Back-compat: `CLAUDE_SAFE=1 ddev claude` still works. The new `ddev claude safe` form is the ergonomic alternative.

Implementation sketch:

```bash
CONTAINER="ddev-${DDEV_SITENAME}-claude"

ensure_running() {
  docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" \
    || { echo "error: sidecar '$CONTAINER' not running"; exit 1; }
}
ensure_firewall() {
  docker exec "$CONTAINER" sudo /usr/local/bin/init-firewall.sh
}
launch_claude() {
  ensure_running
  ensure_firewall
  local args=()
  [[ "${CLAUDE_SAFE:-0}" != "1" ]] && args+=(--dangerously-skip-permissions)
  exec docker exec -it --user claude --workdir /var/www/html \
    "$CONTAINER" claude "${args[@]}" "$@"
}
rebuild_image() {
  bash "$DDEV_APPROOT/.ddev/claude/build-image.sh"
  echo "Regenerated .ddev/claude/Dockerfile. Run 'ddev restart' to apply."
}
show_help() {
  cat <<'HELP'
Usage:
  ddev claude                  Interactive Claude Code session (YOLO mode).
  ddev claude safe             Same, but without --dangerously-skip-permissions.
  ddev claude shell [args]     Drop into bash inside the sidecar.
  ddev claude exec <cmd>       Run one command in the sidecar non-interactively.
  ddev claude rebuild          Regenerate Dockerfile from .ddev/claude.yaml.
  ddev claude help             Print this help.
  ddev claude <other args>     Pass through to the claude CLI.
HELP
}

case "${1:-}" in
  safe)    shift; CLAUDE_SAFE=1 launch_claude "$@" ;;
  shell)   shift; ensure_running; ensure_firewall;
           exec docker exec -it --user claude --workdir /var/www/html "$CONTAINER" bash "$@" ;;
  exec)    shift; ensure_running; ensure_firewall;
           exec docker exec -i  --user claude --workdir /var/www/html "$CONTAINER" "$@" ;;
  rebuild) shift; rebuild_image; exit 0 ;;
  help)    show_help; exit 0 ;;
  *)       launch_claude "$@" ;;
esac
```

### Install manifest (`install.yaml`)

`project_files` list expanded:

```yaml
project_files:
  - docker-compose.claude.yaml
  - claude/Dockerfile.base
  - claude/build-image.sh
  - claude/init-firewall.sh
  - claude/extras/php.fragment
  - claude/extras/php.domains
  - commands/host/claude
  - config.claude.yaml          # ships the pre-start-host hook
```

`pre_install_actions` runs the state-dir bootstrap (`setup-state.sh`):
1. Create `.ddev/.claude/` and `.ddev/.claude/bash_history.d/`.
2. Add `/.claude/` and `/claude.local/` entries to `.ddev/.gitignore` (create the file if missing, no-op if already present).
3. Chown the state dir to 1000:1000 best-effort.

`removal_actions` removes addon-managed files only:
- `.ddev/docker-compose.claude.yaml`
- `.ddev/claude/Dockerfile`, `.ddev/claude/Dockerfile.base`, `.ddev/claude/init-firewall.sh`, `.ddev/claude/build-image.sh`, `.ddev/claude/extras/*`, `.ddev/claude/extra-domains.list`, `.ddev/claude/.build-stamp`
- `.ddev/commands/host/claude`
- `.ddev/config.claude.yaml`

Leaves alone: `.ddev/claude.yaml`, `.ddev/.claude/`, `.ddev/claude.local/`. Post-removal banner tells the user how to fully wipe these.

### Pre-start hook (`config.claude.yaml`)

```yaml
#ddev-generated
hooks:
  pre-start:
    - exec-host: ".ddev/claude/build-image.sh"
```

Runs on the host immediately before `ddev start` (or `ddev restart`) hands off to docker-compose. Ensures the generated `Dockerfile` and `extra-domains.list` are current.

## Data flow

A user's edit-build-run cycle:

```
1. User edits .ddev/claude.yaml — e.g., adds `php` to extras.
2. User runs `ddev restart` (or `ddev claude rebuild && ddev restart`).
3. pre-start-host hook fires → build-image.sh
     - reads .ddev/claude.yaml
     - assembles .ddev/claude/Dockerfile from Dockerfile.base + extras/php.fragment
     - assembles .ddev/claude/extra-domains.list from extras/php.domains
     - writes .ddev/claude/.build-stamp
4. ddev hands to docker-compose, which builds the claude service using the
   generated Dockerfile. PHP 8.5 + Composer get installed at this point.
5. Container starts with `sleep infinity`.
6. User runs `ddev claude`.
7. commands/host/claude runs `sudo init-firewall.sh` inside the container.
     - DEFAULT_DOMAINS = github + anthropic + claude.ai
     - + .ddev/claude/extra-domains.list (packagist.org, repo.packagist.org)
     - + project extra_allowed_domains
     - + EXTRA_ALLOWED_DOMAINS env
     - All collapsed into the dnsmasq config and ipset allow-list.
8. claude binary is exec'd inside the container as uid 1000 with
   --dangerously-skip-permissions, with the firewall active.
```

## Error handling

All errors surface as clean shell exit codes with human-readable messages on stderr. Specific cases:

| Scenario | Behavior |
|---|---|
| `.ddev/claude.yaml` references an unknown extra | `build-image.sh` exits 1 with `error: unknown extra 'foo' (available: php)` |
| `.ddev/claude.yaml` has an invalid top-level key | `build-image.sh` exits 1 with `error: unknown key 'bar' in .ddev/claude.yaml (allowed: extras, extra_allowed_domains)` |
| `.ddev/claude.yaml` exists but is malformed (parser can't make sense of it) | `build-image.sh` exits 1 with `error: failed to parse .ddev/claude.yaml at line N` |
| Cyclic `.requires` dependency | `build-image.sh` exits 1 with `error: dependency cycle in extras: foo -> bar -> foo` |
| `claude/extras/<name>.fragment` referenced but `<name>.domains` missing | Treated as zero domain contributions. Not an error (some extras legitimately have no runtime allow-list needs). |
| Sidecar container not running when user invokes `ddev claude` | Existing message: `error: sidecar '<name>' is not running. hint: run 'ddev start'`. |
| Firewall init fails inside sidecar | `init-firewall.sh` dies hard with a colored error. `ddev claude` exits non-zero before launching claude. |
| Claude installer fetch fails at build time | Docker build fails with non-zero exit; user sees the curl error in build output. |

## Testing

Bats tests in `tests/test.bats`, run by `.github/workflows/tests.yml`. Four groups:

**A. Isolation invariants** — run inside the built sidecar:
1. `iptables -L OUTPUT -n | head -1` shows `policy DROP`.
2. `curl --max-time 3 https://example.com` fails (exit non-zero or curl exit 28/7).
3. `curl --max-time 5 https://api.github.com` succeeds.
4. `id -u` returns `1000`.
5. Host home paths (`/Users/$USER`, `/home/$USER`) do not exist inside the container.
6. `sudo apt-get install -y htop` rejected with sudoers error (NOPASSWD scope is firewall script only).

**B. Build pipeline:**
7. No `.ddev/claude.yaml` → image builds; `docker exec ... which php` is empty; `docker exec ... which gh` is empty.
8. `extras: [php]` → `docker exec ... php -v` shows 8.5; `docker exec ... composer --version` works; `packagist.org` resolves to an IP that's a member of `allowed-ipv4`.
9. `extras: [bogus]` → `build-image.sh` exits non-zero with the unknown-extra message.
10. Malformed `.ddev/claude.yaml` (unknown top-level key) → clear error from `build-image.sh`.
11. `.ddev/claude.local/Dockerfile.fragment` containing `RUN touch /tmp/marker-from-fragment` → marker present in built image.

**C. State and config:**
12. After first `ddev start`, `.ddev/.claude/` exists on the host.
13. `.ddev/.gitignore` contains `/.claude/` and `/claude.local/`.
14. `ddev addon remove claude` removes addon-managed files (per the list in `removal_actions`). Leaves `.ddev/claude.yaml`, `.ddev/.claude/`, `.ddev/claude.local/` intact.

**D. CLI:**
15. `ddev claude help` lists the subcommands (`safe`, `shell`, `exec`, `rebuild`, `help`).
16. `ddev claude exec id -u` returns `1000` on stdout.
17. `ddev claude exec false` exits non-zero (exit code propagation).
18. `ddev claude --version` reaches the claude binary (it handles or rejects it).
19. `ddev claude rebuild` regenerates `.ddev/claude/Dockerfile` (mtime or content changes when `.ddev/claude.yaml` has changed; no-op when nothing changed).
20. `CLAUDE_SAFE=1 ddev claude exec true` — claude was invoked **without** `--dangerously-skip-permissions`. Asserted via a `CLAUDE_BIN_OVERRIDE` env var pointing at an argv-logging wrapper inside the sidecar; the test inspects the logged argv.

CI matrix: minimum two builds — `extras=[]` and `extras=[php]`. Optional third: a non-trivial `.ddev/claude.local/Dockerfile.fragment` smoke build to exercise the escape hatch.

## Open issues / future work

These are intentionally **out of scope** for the MVP but flagged for future iterations:

1. **`read_only: true` root filesystem.** Add `read_only: true` to the compose service with explicit tmpfs mounts for the paths `init-firewall.sh` writes (`/etc/dnsmasq.d`, `/run`, `/var/log`) and switch `/etc/resolv.conf` provisioning to docker-compose's `dns:` directive. Would make the agent literally unable to write outside the bind-mount + named state dir + tmpfs.
2. **DNS-tunneling mitigation.** Today port 53 is open outbound so dnsmasq can reach upstreams. A determined agent could DNS-tunnel small payloads. Restricting port 53 to the host gateway / Docker embedded DNS would close this.
3. **Catalog expansion.** When real demand surfaces, add catalog entries for `node`, `gh`, `playwright`. Each is "shape it like `php`": fragment + `.domains` (+ optional `.requires`). The `.requires` machinery is already in `build-image.sh` for `playwright`.
4. **Better installer trust.** If Anthropic publishes a stable apt repo or a checksummed tarball URL for Claude Code, swap the `curl | bash` for that.
5. **`ddev claude logs` / `ddev claude status`.** Convenience subcommands. Not in MVP; trivial to add when wanted.
