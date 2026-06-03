# Changelog

All notable changes to this add-on are documented here. This project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and the format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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

[v0.3.0-beta.1]: https://github.com/makraz/ddev-claude/releases/tag/v0.3.0-beta.1
[v0.2.0]: https://github.com/makraz/ddev-claude/releases/tag/v0.2.0
[v0.1.0]: https://github.com/makraz/ddev-claude/releases/tag/v0.1.0
