# Changelog

All notable changes to this add-on are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and the format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Security
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
