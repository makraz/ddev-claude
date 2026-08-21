# Releasing ddev-claude

This is a **DDEV add-on**, not a PHP/Composer package. It has no `composer.json` and is not on
Packagist. Distribution is:

- `ddev add-on get makraz/ddev-claude` — resolves to the **latest non-prerelease GitHub release**
- the DDEV add-on registry, which discovers repos by the `ddev-addon` / `ddev-get` topics
- `ghcr.io/makraz/ddev-claude-base:<tag>` — the pre-built sidecar base image, published by
  `publish-image.yml` on tag push

So a "release" here means four things landing together: a git tag, a GitHub Release, a published
base image, and a `Dockerfile.base` pin that references it.

---

## The rule that bites hardest

**`ddev add-on get` installs the latest release that is not marked pre-release.** Mark a release
as a pre-release and users do not get it — they silently stay on the last stable.

That is not hypothetical. Between 2026-06-03 and 2026-08-21 the newest stable was `v0.2.0`, so
every install pulled June's code while three `v0.3.0-beta.*` pre-releases carried the firewall
hardening — firewall active at container start, tamper-proof allow-list, IPv6 fail-loud, Sury key
pinning. None of it reached a single user for two and a half months.

**Decide deliberately, every time:** a pre-release is for testing by people you tell directly. If
the change should reach users, it needs a stable release.

---

## Version scheme

Semver, currently pre-1.0, so the compatibility promise is weaker by design:

- **MAJOR** — reserved for 1.0 and beyond.
- **MINOR** — new capability, or a break. Pre-1.0, breaks land in MINOR and are shouted about in
  the changelog under `### Changed — BREAKING`.
- **PATCH** — fixes, doc changes, image rebuilds.
- **`-beta.N`** — pre-release, opt-in only. Not delivered by `ddev add-on get`.

The base image tag tracks the add-on version 1:1. No floating `:latest`.

## What "breaking" means for this add-on

Not just config-file changes. Any of these breaks an existing project on upgrade:

- a default that changes behaviour (`tools:`, `plugins:` defaulting to a restricted set)
- state moving (host directory → Docker volume)
- the container's user identity changing (fixed uid → host uid)
- a firewall rule narrowing (port 53 restricted to known upstreams)
- anything requiring `ddev claude rebuild` rather than just `ddev restart`

Each of those shipped in v0.4.0. Each needed a changelog entry a user would actually notice.

---

## Release procedure

**1. Land everything on `main` first.**
`main` must equal what you are about to tag. It is legitimate to release from a branch, but then
`main` no longer represents anything shipped, its scheduled CI tests code nobody develops against,
and the next contributor branches from the wrong base. That happened here: `main` sat 12 commits
behind `v0.3.0-beta.3` for two months with failing CI.

**2. Confirm CI is green on `main`.** Not on your branch — on `main`.

**3. Finalise `CHANGELOG.md`.** Move `[Unreleased]` into a dated version heading. Keep a Changelog
sections, in this order: `Changed — BREAKING`, `Security`, `Added`, `Changed`, `Fixed`, `Removed`.
Every user-visible change gets an entry, including bug fixes that predate the release — a fix
nobody can find is a fix nobody trusts.

**4. Bump the base image pin** in `claude/Dockerfile.base` to the version you are about to tag.
The image does not exist yet; `publish-image.yml` creates it on tag push. CI builds it locally
(`tests.yml` extracts the tag from `Dockerfile.base` and runs `docker build image/`) so pull
requests work before the tag exists.

**5. Tag annotated, from `main`.**

```bash
git tag -a v0.4.0 -m "v0.4.0"
git push origin v0.4.0
```

**6. Wait for `publish-image.yml` to go green** before telling anyone. Between the tag push and
the multi-arch build finishing (~3–5 min), `Dockerfile.base` points at an image that does not
exist, and any `ddev restart` fails to pull it.

**7. Create the GitHub Release** from the tag, changelog section as the body. Mark pre-release
**only** if you genuinely do not want users to receive it.

**8. Verify the published artifact.**

```bash
docker manifest inspect ghcr.io/makraz/ddev-claude-base:v0.4.0   # both arches present
docker inspect ghcr.io/makraz/ddev-claude-base:v0.4.0 | grep -i claude-code-version
```

That second check matters: the image bakes whatever `claude.ai/install.sh` serves **at build
time**, so the CLI version inside an image is decided by when the workflow ran, not by the tag.
Two rebuilds of the same tag are not the same artifact.

**9. Smoke-test a real install** on a project you did not develop against:

```bash
ddev add-on get makraz/ddev-claude && ddev restart && ddev claude exec id -u
```

---

## Never re-push an existing release tag

Force-pushing a tag re-triggers `publish-image.yml`, which rebuilds that version's image with
today's Claude CLI. The image tagged `v0.3.0-beta.3` would no longer contain what
`v0.3.0-beta.3` shipped. If a released tag is wrong, release a new patch version instead.

The only safe exception is a tag that was never publicly consumed, and even then, prefer a new
version.

---

## Known gaps in the current pipeline

Recorded so they are chosen rather than forgotten:

| Gap | Consequence |
| --- | --- |
| CI runs only `ubuntu-22.04`, single arch | The Mutagen mount path is never exercised. That is exactly how the uid lockout — the agent unable to read the project at all — reached a final review undetected. |
| No DDEV version matrix | `ddev_version_constraint` claims `>= v1.24.0`; CI tests one version, whatever the runner installs. |
| Two integration tests depend on the public internet | `downloads.claude.ai` and `packages.sury.org` reachability. They flake under load and will flake in CI. |
| Release notes written by hand | Fine at this cadence, drifts at higher cadence. |
| No arm64 test | The image is multi-arch; only amd64 is tested. |
