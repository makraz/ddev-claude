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

## Artifact integrity — the weakest part of this pipeline

The release *mechanics* here are reasonable. The guarantees about *what you shipped* are not, and
for an add-on whose entire purpose is sandboxing, that inversion matters more than it would
elsewhere. Four specifics, all currently true:

**1. The published image is not reproducible.** `image/Dockerfile:43` is:

```dockerfile
RUN curl -fsSL https://claude.ai/install.sh | bash
```

No version pin. The Claude Code version inside the image is whatever that endpoint served at the
moment the workflow ran. Two builds of the *same tag* are different artifacts, and there is no way
to reconstruct what a past release contained. The Dockerfile comment says the version is "captured
in an OCI label so `docker inspect` shows what's baked in" — a label records the outcome, it does
not make it reproducible or verifiable.

**2. That install is unverified.** A `curl | bash` from a remote host, with no checksum and no
signature, executed at image build time. The result is baked into an image that later runs with
`NET_ADMIN` and `NET_RAW`. The `php` extra pins and fingerprint-verifies the Sury signing key
precisely because trusting an unverified remote was judged unacceptable there — the same standard
is not applied to the agent binary itself.

**3. Nothing is attested.** `publish-image.yml` has zero occurrences of provenance, attestation,
SBOM or signing. Users pulling `ghcr.io/makraz/ddev-claude-base:<tag>` cannot verify it was built
from this repo at that tag. `docker/build-push-action` supports `provenance:` and
`sbom:` inputs; GitHub provides `actions/attest-build-provenance`. None are used.

**4. Tags are unsigned.** `git verify-tag v0.3.0-beta.3` → *no signature found*. For a project
distributing a security tool, a signed tag is the cheapest possible assertion that a release came
from you.

### Minimum bar to fix this

- Pin the CLI: `ARG CLAUDE_VERSION` with an explicit default, verify a checksum, and fail the
  build on mismatch — the treatment the Sury key already gets.
- Add `provenance: mode=max` and `sbom: true` to the build-push step.
- Sign tags (`git tag -s`), or at minimum enable GitHub's tag protection.
- Record the resolved CLI version in the release notes, not only in an OCI label.

## Repository governance

`main` is **not protected** (`GET /branches/main/protection` → 404). It was force-pushed during
this release with nothing to stop it. For a public repo that distributes an executable sandbox,
the baseline is: require the `tests` check to pass, disallow force-push, and require a PR to
merge. That is also the mechanism that would have prevented `main` from silently falling 12
commits behind its own releases.

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
| CLI version unpinned in the image | Same tag rebuilds to a different artifact; no way to reconstruct a past release. |
| No provenance / SBOM / signature | Users cannot verify the image came from this repo at that tag. |
| Tags unsigned | No cryptographic assertion that a release is yours. |
| `main` unprotected | Force-pushable; nothing enforces that CI passed before a merge. |
