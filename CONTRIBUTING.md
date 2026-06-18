# Contributing to ddev-claude

Thanks for helping improve this add-on. This guide covers how to propose changes,
the project conventions, and the one place outside contributions are most
welcome: the **extras catalog**.

> Found a security issue (firewall bypass, sandbox escape, secret exposure)?
> **Do not open a public issue or PR.** Follow [SECURITY.md](SECURITY.md) instead.

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you
are expected to uphold it.

## Before you start

- **Bugs**: open an issue first with your DDEV version (`ddev version`), host OS +
  architecture (`uname -m`), the add-on version, and the relevant output
  (`init-firewall.sh` / `build-image.sh` logs). Firewall and architecture bugs
  are the most common failure class, so those details matter.
- **Features / new extras**: open an issue to discuss before writing code. For
  design-heavy changes (anything touching the firewall, the base image, or the
  `build-image.sh` pipeline), a short written proposal in the issue — problem,
  options, chosen approach — saves everyone a round trip.

## Development setup

You need [DDEV](https://ddev.com) (`>= v1.24.0`), Docker, and
[`bats`](https://github.com/bats-core/bats-core) for the tests.

```bash
# Run the test suite
bats tests/

# tests/build-image.bats — unit tests for the Dockerfile/domains parser
# tests/test.bats        — integration tests (installs the add-on into a scratch project)
```

For a manual smoke test, install your working copy into a throwaway DDEV project
and exercise the real commands:

```bash
ddev add-on get /path/to/your/ddev-claude   # local checkout
ddev restart
ddev claude shell        # firewall active, drop into bash
ddev claude exec -- echo ok
```

## Adding an extra (the easy, encouraged path)

The extras catalog is the safe, bounded extension point — it lets you add tooling
to the sidecar **without touching the firewall core**. Each extra is a small set
of files in `claude/extras/<name>.*`:

| File | Required | Purpose |
| --- | --- | --- |
| `<name>.fragment` | ✅ | Dockerfile snippet spliced in at the `{{EXTRAS}}` marker. Install your tool here. |
| `<name>.domains`  | optional | One outbound domain per line, added to the runtime firewall allow-list when the extra is enabled. |
| `<name>.requires` | optional | Names of other extras this one depends on, one per line. |

Use the existing `php` extra as the template. Conventions:

- Start the fragment with `#ddev-generated` and a one-line comment describing the
  extra and pointing at its `.domains` file.
- Switch to `USER root` for `apt-get`, clean up in the **same `RUN`** layer
  (`apt-get purge --auto-remove` build-deps, `rm -rf /var/lib/apt/lists/*`), and
  keep the image lean.
- List **only** the domains the tool needs at runtime in `<name>.domains` — keep
  the default sandbox tight. Build-time-only domains do not belong here.
- Add the extra's name to the "Available extras" line in `README.md` and the
  config example.
- Add or extend a case in `tests/build-image.bats` so the parser is covered.

Enabling an extra is then just:

```yaml
# .ddev/claude.yaml
extras:
  - <name>
```

## Conventions

- **Commits**: [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `test:`, `ci:`, `docs:`, `chore:`). This drives the changelog
  and the version bump.
- **Branches**: short-lived, off `main`, named like `fix/<slug>` or `feat/<slug>`.
- **Shell scripts**: `set -euo pipefail`, must stay POSIX/portability-safe across
  Linux and macOS hosts (a recent bug was GNU-vs-BSD `stat` differences). Keep the
  `#ddev-generated` header on generated/managed files.
- **Changelog**: add an entry under `## [Unreleased]` in
  [`CHANGELOG.md`](CHANGELOG.md) ([Keep a Changelog](https://keepachangelog.com/)
  format) in the same PR as your change.

## Pull requests

1. Branch from `main`, make your change, add/extend tests.
2. Run `bats tests/` locally — it must pass. CI builds the base image locally for
   PRs, so tests run without a published image.
3. Add your `## [Unreleased]` changelog entry.
4. Open the PR describing **why**, **what changed**, and **how you tested it**
   (including the host OS/arch you tested on).
5. PRs are **squash-merged**, so write a clear PR title — it becomes the commit on
   `main`.

CI (`tests.yml`) must be green before merge.

## Releases

Releases are maintainer-driven and tag-based: pushing a `vX.Y.Z` tag triggers
`publish-image.yml`, which builds and publishes the multi-arch base image
`ghcr.io/makraz/ddev-claude-base:<version>` (the image tag is pinned 1:1 to the
add-on version). Version bumps follow [SemVer](https://semver.org/):

- **patch** — bug/portability fixes
- **minor** — new extra, new `ddev claude` subcommand, backward-compatible additions
- **major** — anything that breaks existing `.ddev/claude.yaml` files or requires
  users to re-run `ddev add-on get`

Architecture-level changes ship as `-beta.N` pre-releases first, then get promoted
to a stable tag.

## License

By contributing, you agree your contributions are licensed under the
[MIT License](LICENSE) that covers this project.
