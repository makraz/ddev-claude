# Changelog

All notable changes to this add-on are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and the format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [v0.4.0-beta.1] — 2026-08-19

### Changed — BREAKING
- The agent's built-in tool set is now restricted. With no `tools:` key in
  `.ddev/claude.yaml`, the default is `Read`, `Write`, `Bash`, `Skill` —
  `Edit`, `Grep`, `Glob`, `Task`, `WebFetch`, `WebSearch`, `NotebookEdit`,
  `TodoWrite` and `SlashCommand` are off. Existing projects with no `tools:` key
  are affected on upgrade. Add a `tools:` list to opt back in. Applied by a
  `claude` shim ahead of the real binary on `PATH`, so it covers `ddev claude`,
  `ddev claude shell`, `ddev claude exec` and plain `docker exec`.
  **This is a default and a cost control, not a containment boundary:** a login
  shell (`bash -l`) sources `~/.profile`, which finds the real binary first, and
  `Bash` in the default set lets the agent invoke that binary directly. The shim
  runs as the agent's own uid, so nothing here could prevent that. The CLI scopes
  `--tools` to built-in tools, so its effect on MCP tools is unverified — omit an
  MCP server rather than relying on `tools:` to disable it.
- Plugins are now curated. With no `plugins:` key the default is `superpowers`,
  `code-review`, `gitlab`, `code-simplifier` — the interpreter-free set. This
  fixes the `FATAL: No working Python found` that Python-backed plugins
  (`remember`, `security-guidance`) emitted on every `PostToolUse` hook, since
  the image ships no Python by design.
- Claude's state moved from `.ddev/.claude/` to a Docker volume
  (`${DDEV_SITENAME}_claude_state`). It is seeded from the old directory on
  first start; the old directory is left in place. `ddev claude state` copies
  the volume back out. `ddev add-on remove claude` does not delete the volume.

### Added
- `python` and `node` extras, for projects that want the Python- or Node-backed
  plugins. Both install from Debian's own repositories, so neither adds a
  third-party apt signing key to trust.
- `tools:`, `plugins:` and `mount_mode:` keys in `.ddev/claude.yaml`.
  `mount_mode` is the first scalar key the parser accepts.
- `ddev claude state [dir]` — copy the sidecar's `~/.claude` out to a directory.
- `docs/PERFORMANCE.md`, with the measurements and a reproducible benchmark.

### Changed
- Firewall diagnostics are no longer printed on the success path. `ddev claude`,
  `shell` and `exec` used to emit `[firewall] …` lines before the command's own
  output on every invocation. Failures are still surfaced in full.
- `.credentials.json` is now copied back to `.ddev/.claude/` when a session
  exits, so authentication survives even if the state volume is deleted. Note
  this means deleting the volume no longer forces re-authentication — a fresh
  volume re-seeds the credential file from there.
- The curated plugin set is applied by passing `--settings` at launch rather than
  by writing into the agent's `~/.claude/settings.json`. An earlier build of this
  release overwrote that file on every container start with one containing only
  `enabledPlugins`, which destroyed any model, hooks, statusline or env settings
  the user had. The user's file is now never modified. Note the limit of this:
  `--settings` force-enables the curated set on every launch but cannot
  force-disable a plugin it does not list, so a plugin the agent enables does
  persist in its own state. That is the accepted trade for not destroying the
  user's settings — the plugin layer is a default, not a boundary.

### Fixed
- The sidecar no longer bind-mounts the project from the host when Mutagen is
  enabled. It now shares `web`'s synced volume. Measured as the agent on one
  host (macOS, OrbStack, DDEV v1.25.3, 86 MB / 13,017-file corpus): a `grep` over
  `vendor/` went from 28.4 s to 0.065 s, and a `find` from 0.68 s to 0.019 s.
  That is one machine's result, not a guarantee — see `docs/PERFORMANCE.md` for
  the method and how to reproduce it. Set `mount_mode: bind` to opt out.
- `ddev add-on remove claude` never actually deleted the files it generates. Its
  removal script runs with the working directory set to `.ddev/`, so every
  `rm -f .ddev/claude/...` resolved one level too deep and silently no-opped —
  `rm -f` does not error on a missing path. Dates to commit `749d3b3`.
- `ddev claude exec <cmd>` leaked the firewall's own log output into its stdout,
  breaking any consumer that parsed the command's output. The health check's
  output is now captured and shown only if the check fails.
- `ddev claude` refuses to start while the Mutagen sync is still staging.
  Previously the agent saw an empty or half-populated `/var/www/html` and
  reported that files did not exist.
- The Mutagen-synced volume above is populated with real POSIX ownership from
  the host (files `0600`, directories `0700`, owned by the host uid) — unlike
  the bind mount it replaced, which always presented files as owned by
  whichever container user accessed them. Without a matching uid, the agent
  (uid 1000) could not read, write, or even traverse the project at all.
  `entrypoint.sh` now remaps the `claude` user to the host's uid/gid
  (`DDEV_UID`/`DDEV_GID`, forwarded from `docker-compose.claude.yaml`) at
  every container start, mirroring what DDEV's own `web` container already
  does. The remap never targets uid/gid 0 and is skipped, with a warning, if
  the target uid/gid is already taken by a different account in the
  container. `ddev claude`'s workspace-readiness check now also probes as the
  agent (`--user claude`), not root, on every mount mode, so this class of
  regression cannot pass silently again.

## [v0.3.0-beta.3] — 2026-06-18

### Security
- The `php` extra now pins the Sury (`packages.sury.org`) signing key. The
  downloaded keyring is verified to contain the expected `DEB.SURY.ORG`
  fingerprint before it is trusted; the build fails loudly on a mismatch
  (rotation/tampering), instead of trusting whatever key the endpoint serves.
- IPv6 lockdown now fails loudly. Previously, if `ip6tables` was unavailable the
  firewall silently skipped v6 — leaving an unfiltered egress path on any
  container with IPv6 connectivity. `init-firewall.sh` now `die`s when
  `ip6tables` is missing *and* an IPv6 default route exists.

### Documentation
- Documented the firewall's limitations explicitly: allow-listed hosts (notably
  GitHub, with the agent's token) remain a viable exfiltration channel, so the
  firewall guards against accidental egress rather than a determined
  exfiltrator. Added a "What the firewall does NOT protect against" section to
  `SECURITY.md` and a caveat to the README.

### Changed
- The `ddev claude` firewall re-assert is now near-instant. `init-firewall.sh`
  gained an `--ensure` mode that fast-paths to a no-op when the firewall is
  already healthy, skipping the full reset, per-domain DNS resolution, and curl
  smoke tests that previously ran on every `ddev claude` / `shell` / `exec`
  invocation. A full rebuild still runs at container start and whenever the
  health check fails, so transient start-time failures still self-heal.
- The ddev sibling-service list for dnsmasq static records is no longer
  hardcoded to `web db mailpit`. It is single-sourced, self-pruning (only names
  that resolve get a record), and overridable for non-standard stacks via the
  `DDEV_CLAUDE_SIBLING_HOSTS` environment variable (space-separated). This is a
  DNS convenience only and cannot widen egress — the docker subnet is already
  allowed via the `allowed-net` ipset.

### Internal
- Refactored the shell scripts to remove duplication: a shared `read_list_file`
  helper (comment-strip + trim + skip-blank) in `build-image.sh` and
  `init-firewall.sh`, a `_sha` sha256/shasum fallback helper, and a single
  `discover_extras` source of available extras reused by both `validate_extras`
  and the `.requires` dependency resolver (replacing an inline `ls | sed`). No
  behavior change; covered by the existing `tests/build-image.bats` suite.

## [v0.3.0-beta.2] — 2026-06-12

### Added
- `downloads.claude.ai` in the default firewall allow-list, so `claude update`
  works out of the box.
- `SECURITY.md` documenting the threat model and private vulnerability reporting.
- `CONTRIBUTING.md` with the development workflow and the extras-catalog contribution guide.
- Issue and pull-request templates under `.github/`.

### Security
- The outbound allow-list can no longer be widened from inside the sandbox.
  Previously `init-firewall.sh` read `extra-domains.list` from the rw
  bind-mounted project tree and honored `EXTRA_ALLOWED_DOMAINS` from its own
  environment, so the unprivileged agent could append a domain (or `export` the
  var) and re-run the firewall via the NOPASSWD `sudo` entry to reach arbitrary
  hosts. The allow-list is now read only from root-owned files outside the bind
  mount (`/etc/claude-firewall/{extra-domains,runtime-domains}.list`), the
  script ignores its own environment, and the `env_keep` sudoers entry was
  removed.
- The firewall is now activated at container start by `entrypoint.sh` (PID 1,
  running as root), so `ddev exec -s claude` and direct `docker exec` are
  sandboxed too — not just the `ddev claude` host command.

### Fixed
- `EXTRA_ALLOWED_DOMAINS` now takes effect again: it is consumed once, at
  container start, by `entrypoint.sh` (genuine root, trusted compose env) and
  persisted to a root-owned runtime allow-list. Set it before `ddev start` /
  `ddev restart`.
- Re-running `init-firewall.sh` (which happens on every `ddev claude`) silently
  lost the resolved IP baseline: the old rules were flushed while the DROP
  policies persisted, so the initial DNS resolution phase ran with zero egress
  and allow-listed domains stayed unreachable until dnsmasq happened to
  re-resolve them. The iptables rules are now installed before dnsmasq setup
  and the initial resolution, making the script genuinely idempotent.

### Changed
- Changing `extra_allowed_domains` in `.ddev/claude.yaml` now requires
  `ddev claude rebuild` + `ddev restart` (the list is baked into the image),
  consistent with how `extras` already work.

## [v0.3.0-beta.1] — 2026-06-03

Pre-release. Pre-built image architecture — the default sidecar now pulls a published
multi-arch base image instead of building everything locally.

### Added
- Pre-built multi-arch base image `ghcr.io/makraz/ddev-claude-base:<version>`, published
  from this repo via `.github/workflows/publish-image.yml` on every git tag push
  (`linux/amd64` + `linux/arm64`).
- `image/` directory holding the base image source (`image/Dockerfile`).
- `build-image.sh` parser that generates the per-project `Dockerfile`/domains from
  `.ddev/claude.yaml`, with `.requires` extra-dependency resolution and a build stamp.
- `php` extra (PHP 8.5 + Composer + extensions).
- Unit tests (`tests/build-image.bats`) run alongside integration tests in CI; PRs build
  the base image locally so tests run without a published image.

### Changed
- `claude/Dockerfile.base` slimmed to a thin wrapper: `FROM ghcr.io/.../ddev-claude-base:<version>`
  plus a small COPY/chmod/extras layer. The image tag is pinned 1:1 to the add-on version —
  no floating `:latest`.
- Firewall reads project-local `extra-domains.list`.
- README restructured to match the DDEV official add-on style; env vars and version
  references aligned with the current codebase.

### Fixed
- gitignore entries are written to the project root, not `.ddev/.gitignore`.

## [v0.2.0] — 2026-05-19

Minimum-viable redesign (stable; promoted from `v0.2.0-beta.1`).

### Added
- New `ddev claude` subcommands: `safe`, `shell`, `exec`, `rebuild`, `help`. Flag
  passthrough still works.
- Opt-in extras catalog via `.ddev/claude.yaml` (`extras:` and `extra_allowed_domains:`).
- Escape hatch `.ddev/claude.local/Dockerfile.fragment` for tooling outside the catalog,
  plus a README Cookbook with copy-pasteable gh / Node / Playwright fragments.

### Changed
- Default sidecar stripped to **Claude Code + firewall** on `debian:bookworm-slim`
  (~300 MB vs ~1.5 GB). PHP / Composer / Playwright / Chromium / MCPs / gh moved out of
  the defaults and into opt-in extras.
- Auth state moved from named volumes (`claude-config`, `claude-history`) to
  `.ddev/.claude/`, gitignored at the project root.

### Breaking
- Bundled PHP / Composer / Playwright / gh / MCPs are gone from the default image. Add
  `extras: [php]` to `.ddev/claude.yaml` to restore PHP + Composer; use the Cookbook for
  the rest.
- Named volumes `claude-config` and `claude-history` are replaced by the `.ddev/.claude/`
  bind-mount. **Pre-existing OAuth state in those volumes is NOT migrated automatically** —
  re-auth or copy the volume contents manually.

## [v0.1.0] — 2026-05-06

Initial release.

[v0.3.0-beta.2]: https://github.com/makraz/ddev-claude/releases/tag/v0.3.0-beta.2
[v0.3.0-beta.1]: https://github.com/makraz/ddev-claude/releases/tag/v0.3.0-beta.1
[v0.2.0]: https://github.com/makraz/ddev-claude/releases/tag/v0.2.0
[v0.1.0]: https://github.com/makraz/ddev-claude/releases/tag/v0.1.0
