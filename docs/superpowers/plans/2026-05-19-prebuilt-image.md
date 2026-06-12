# Pre-built Base Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship ddev-claude `v0.3.0-beta.1` — publish a pre-built multi-arch base image to GHCR, slim `claude/Dockerfile.base` to a thin wrapper that pulls it, add a GitHub Actions workflow that publishes on tag push, and tweak the existing CI so PRs can build the image locally.

**Architecture:** A new `image/Dockerfile` produces `ghcr.io/makraz/ddev-claude-base:<version>`. The per-project `claude/Dockerfile.base` becomes `FROM ghcr.io/...:<version>` + a thin COPY/chmod/extras layer. The runtime contract (uid 1000, sudoers entry, firewall script path, extras injection point) is unchanged.

**Tech Stack:** Docker, BuildKit/buildx, QEMU (for arm64 emulation in CI), GitHub Actions, GitHub Container Registry (GHCR), bats-core.

**Reference spec:** `docs/superpowers/specs/2026-05-19-prebuilt-image-design.md`.

---

## File structure (target end-state)

```
ddev-claude/
├── image/                              NEW
│   ├── Dockerfile                      NEW: published image source
│   └── README.md                       NEW: short note about what's inside
├── claude/
│   ├── Dockerfile.base                 MODIFIED: thin wrapper (~14 lines)
│   ├── build-image.sh                  UNCHANGED
│   ├── init-firewall.sh                UNCHANGED
│   └── extras/                         UNCHANGED
├── commands/host/claude                UNCHANGED
├── config.claude.yaml                  UNCHANGED
├── docker-compose.claude.yaml          UNCHANGED
├── install.yaml                        UNCHANGED
├── tests/                              UNCHANGED (existing suite continues to pass)
├── README.md                           MODIFIED: pre-built image + dev workflow notes
└── .github/workflows/
    ├── tests.yml                       MODIFIED: build image locally before bats
    └── publish-image.yml               NEW: multi-arch publish on tag push
```

---

## Conventions used in this plan

- Working directory: `/Users/hamza/Workspace/ddev-claude` (the repo root) unless `cd` is shown.
- Project rule from `~/.claude/CLAUDE.md`: **Never** add `Co-Authored-By: Claude` to any commit.
- Branch: implementation lands on a new branch `feat/prebuilt-image`. Tagging + GHCR publishing happens after the branch merges to `main`.
- Target image tag throughout this branch: `v0.3.0-beta.1`. When the implementer later tags this commit as `v0.3.0-beta.1` and pushes, the new `publish-image.yml` workflow fires and produces the image.
- `bats` means `bats-core` (already installed locally; CI uses `apt-get install bats`).

---

## Task 1: Create `image/Dockerfile`

**Files:**
- Create: `image/Dockerfile`

This is the source of the published image. Structurally identical to today's `claude/Dockerfile.base` **minus** the `COPY init-firewall.sh` / `RUN chmod` block and the `# {{EXTRAS}}` marker — those move to the per-project thin wrapper in Task 3.

- [ ] **Step 1.1: Create the `image/` directory and file**

Write `image/Dockerfile` with exactly this content:

```dockerfile
#ddev-generated
# ---------------------------------------------------------------------------
# ddev-claude pre-built base image.
# Published to ghcr.io/makraz/ddev-claude-base:<git-tag> by
# .github/workflows/publish-image.yml.
#
# This image bundles the runtime: debian-slim + 10 packages + the unprivileged
# `claude` user (uid 1000) + the sudoers entry + the Claude Code native binary.
# It does NOT contain init-firewall.sh (which changes with addon releases)
# or any extras (which are project-specific).
# ---------------------------------------------------------------------------
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

# Install Claude Code via the official native installer at image build time.
# The exact version is whatever https://claude.ai/install.sh resolves to when
# publish-image.yml runs; that version is captured in an OCI label so
# `docker inspect` shows what's baked in.
USER claude
WORKDIR /home/claude
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/claude/.local/bin:${PATH}"

WORKDIR /var/www/html
```

- [ ] **Step 1.2: Smoke-build the image locally**

Run:
```
docker build -t ghcr.io/makraz/ddev-claude-base:v0.3.0-beta.1 image/
```
Expected: build succeeds. Final size ~300–400 MB. The Claude Code installer fetches from `https://claude.ai/install.sh`; if it errors, troubleshoot before proceeding.

- [ ] **Step 1.3: Verify the image actually runs claude**

Run:
```
docker run --rm ghcr.io/makraz/ddev-claude-base:v0.3.0-beta.1 /home/claude/.local/bin/claude --version
```
Expected: claude prints a version string (any version). If "command not found", the installer didn't land the binary where we expect — read the build output and adjust `PATH` accordingly.

- [ ] **Step 1.4: Commit**

Run:
```
git checkout -b feat/prebuilt-image
git add image/Dockerfile
git commit -m "feat: image source for ddev-claude-base"
```

The locally-built image stays in your Docker cache; later tasks rely on it being present.

---

## Task 2: Create `image/README.md`

**Files:**
- Create: `image/README.md`

A short note documenting what's in the image and how to consume it.

- [ ] **Step 2.1: Create `image/README.md`**

Write `image/README.md` with exactly this content:

````markdown
# ddev-claude base image

Source of the pre-built sidecar image published to
`ghcr.io/makraz/ddev-claude-base:<tag>`.

## What's inside

- `debian:bookworm-slim` base
- `ca-certificates curl git bash sudo iptables ipset dnsmasq dnsutils iproute2`
- An unprivileged `claude` user (uid 1000) with a NOPASSWD sudoers entry
  scoped to `/usr/local/bin/init-firewall.sh`
- The Claude Code native binary at `/home/claude/.local/bin/claude`

## What's NOT inside

- `init-firewall.sh` — copied in by the addon's per-project wrapper
  (`claude/Dockerfile.base`), because it changes more often than this image.
- Any extras (PHP, gh, Playwright, etc.) — those install per project via
  the catalog at `claude/extras/` and the escape hatch
  `.ddev/claude.local/Dockerfile.fragment`.

## Versioning

The image tag equals the addon's git tag, 1:1. There is **no `:latest`** —
consumers pin to a specific addon version, which pins to a specific image.

The Claude Code binary version baked into each image is recorded in the OCI
label `io.makraz.ddev-claude.claude-version`. Inspect with:

```bash
docker inspect ghcr.io/makraz/ddev-claude-base:v0.3.0 \
  --format '{{ index .Config.Labels "io.makraz.ddev-claude.claude-version" }}'
```

## Building locally

```bash
docker build -t ghcr.io/makraz/ddev-claude-base:v0.3.0 image/
```

Docker's default pull policy is `missing`, so a local image with the same tag
takes precedence over the published one. Useful for iterating on
`image/Dockerfile` without publishing.
````

- [ ] **Step 2.2: Commit**

Run:
```
git add image/README.md
git commit -m "docs: image/README describing the base image"
```

---

## Task 3: Slim `claude/Dockerfile.base` + extend `tests.yml`

**Files:**
- Modify: `claude/Dockerfile.base`
- Modify: `.github/workflows/tests.yml`

These two changes land **together** in one commit because they're interdependent: the new `Dockerfile.base` references `ghcr.io/.../ddev-claude-base:v0.3.0-beta.1`, which doesn't exist in GHCR yet — so the test workflow must build it locally before bats runs. Splitting these would break CI on either side.

- [ ] **Step 3.1: Replace `claude/Dockerfile.base` with the thin wrapper**

Write `claude/Dockerfile.base` with exactly this content:

```dockerfile
#ddev-generated
# ---------------------------------------------------------------------------
# Per-project sidecar Dockerfile template (v0.3.0+).
#
# The heavy lifting (packages, claude binary, claude user, sudoers entry) is
# done in the pre-built image referenced by FROM. This file is the TEMPLATE
# build-image.sh works against; it inlines selected extras at the marker
# below.
# ---------------------------------------------------------------------------
FROM ghcr.io/makraz/ddev-claude-base:v0.3.0-beta.1

USER root
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod 0755 /usr/local/bin/init-firewall.sh

# ---- EXTRAS INJECTION POINT ----
# build-image.sh replaces the marker line below with the concatenated
# contents of every selected claude/extras/<name>.fragment, followed by
# .ddev/claude.local/Dockerfile.fragment if it exists. Fragments execute as
# root (the current USER context here). If a fragment switches USER, it must
# restore `USER root` before its end.
# {{EXTRAS}}
# --------------------------------

USER claude
WORKDIR /var/www/html
```

Note: the descriptive comment intentionally says "the marker line below" — it does **not** contain the literal `# {{EXTRAS}}` in backticks. This avoids a false-positive in `tests/build-image.bats`'s "empty config → marker is replaced" assertion (this was the same fix we applied during v0.2.0 development).

- [ ] **Step 3.2: Add the local-build step to `.github/workflows/tests.yml`**

The current `tests.yml` has a single "Run tests" step that runs both bats files. Before that step, the runner needs to build the image locally so the integration tests' `ddev restart` can find it.

Edit `.github/workflows/tests.yml` to insert a new step BEFORE `Run tests`. The full updated file should look like:

```yaml
name: tests

on:
  push:
    branches: [main]
  pull_request:
  schedule:
    - cron: '15 6 * * 1'  # weekly Monday 06:15 UTC — catches upstream drift
  workflow_dispatch:

defaults:
  run:
    shell: bash

jobs:
  test:
    name: addon-test
    runs-on: ubuntu-22.04
    env:
      DDEV_NONINTERACTIVE: 'true'
    steps:
      - uses: actions/checkout@v4

      - name: Install DDEV
        run: |
          curl -fsSL https://ddev.com/install.sh | bash
          ddev version

      - name: Install bats
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y bats

      - name: Build base image locally (so PR CI works before the tag is published)
        run: |
          TAG=$(grep -m1 'FROM ghcr.io/.*/ddev-claude-base:' claude/Dockerfile.base | sed 's|.*:||')
          if [ -z "$TAG" ]; then
            echo "could not extract base image tag from claude/Dockerfile.base" >&2
            exit 1
          fi
          docker build -t "ghcr.io/${{ github.repository_owner }}/ddev-claude-base:${TAG}" image/

      - name: Run tests
        run: |
          bats tests/build-image.bats
          bats tests/test.bats
```

The only delta vs the existing file is the new "Build base image locally" step plus the existing "Run tests" step gaining a `bats tests/build-image.bats` line (it may already be there from the v0.2.0 implementation; if so, no change to that line).

- [ ] **Step 3.3: Verify the wrapper builds locally**

The image from Task 1 is already in your Docker cache with tag `v0.3.0-beta.1`. Build the wrapper using a smoke Dockerfile pointed at `./claude`:

Run:
```
cp claude/Dockerfile.base claude/Dockerfile.smoketest && \
  docker build -t ddev-claude-wrapper-smoke -f claude/Dockerfile.smoketest claude/ && \
  rm claude/Dockerfile.smoketest
```
Expected: build succeeds in seconds (most of the work is cached from Task 1's image build).

- [ ] **Step 3.4: Smoke-run the wrapper image**

Run:
```
docker run --rm --user claude --workdir /home/claude ddev-claude-wrapper-smoke /home/claude/.local/bin/claude --version
```
Expected: claude prints a version string (same as Task 1.3).

- [ ] **Step 3.5: Verify `init-firewall.sh` was copied in by the wrapper**

Run:
```
docker run --rm ddev-claude-wrapper-smoke ls -l /usr/local/bin/init-firewall.sh
```
Expected: file exists, mode `-rwxr-xr-x` (0755).

- [ ] **Step 3.6: Clean up the smoke image**

Run:
```
docker rmi ddev-claude-wrapper-smoke
```
Expected: untagged + removed.

- [ ] **Step 3.7: Run the bats unit tests to confirm nothing broke**

Run:
```
bats tests/build-image.bats
```
Expected: `12 tests, 0 failures`. If any test fails, the most likely cause is a stray `# {{EXTRAS}}` in the descriptive comment of `Dockerfile.base` — check Step 3.1 and ensure the comment says "the marker line below" with no backticks containing the literal.

- [ ] **Step 3.8: Commit**

Run:
```
git add claude/Dockerfile.base .github/workflows/tests.yml
git commit -m "feat: thin Dockerfile.base wrapper + CI local image build"
```

---

## Task 4: Create `.github/workflows/publish-image.yml`

**Files:**
- Create: `.github/workflows/publish-image.yml`

The multi-arch publish workflow that fires on tag push.

- [ ] **Step 4.1: Create the workflow**

Write `.github/workflows/publish-image.yml` with exactly this content:

```yaml
name: publish-image

on:
  push:
    tags:
      - 'v*'           # any version tag, including pre-releases like v0.3.0-beta.1
  workflow_dispatch:    # manual fallback

permissions:
  contents: read
  packages: write       # GHCR push

jobs:
  build-and-push:
    name: build & push base image
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4

      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.repository_owner }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Capture Claude Code version
        run: |
          CLAUDE_VERSION=$(docker run --rm debian:bookworm-slim bash -c '
            apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null &&
            curl -fsSL https://claude.ai/install.sh | bash >/dev/null &&
            ~/.local/bin/claude --version
          ' | head -1)
          echo "CLAUDE_VERSION=$CLAUDE_VERSION" >> "$GITHUB_ENV"
          echo "Resolved Claude Code version: $CLAUDE_VERSION"

      - name: Build & push
        uses: docker/build-push-action@v6
        with:
          context: image
          platforms: linux/amd64,linux/arm64
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/ddev-claude-base:${{ github.ref_name }}
          labels: |
            org.opencontainers.image.source=https://github.com/${{ github.repository }}
            org.opencontainers.image.version=${{ github.ref_name }}
            org.opencontainers.image.licenses=MIT
            io.makraz.ddev-claude.claude-version=${{ env.CLAUDE_VERSION }}
```

- [ ] **Step 4.2: Validate the workflow YAML**

GitHub Actions doesn't strictly require lint, but it helps to catch typos. Use `yq` (which DDEV ships) or `python -c 'import yaml; yaml.safe_load(open("..."))'`. The simplest cross-platform check:

Run:
```
python3 -c 'import sys, yaml; yaml.safe_load(open(".github/workflows/publish-image.yml"))' && echo OK
```
Expected: `OK`. If you see a `yaml.YAMLError`, fix the indentation/quoting.

- [ ] **Step 4.3: Commit**

Run:
```
git add .github/workflows/publish-image.yml
git commit -m "ci: publish-image workflow for multi-arch GHCR build on tag push"
```

The workflow won't run until a `v*` tag is pushed (or it's manually dispatched). It can sit dormant for the rest of this plan; the next task (`Task 6`) will exercise it.

---

## Task 5: Update `README.md`

**Files:**
- Modify: `README.md`

Document the pre-built image, the version-pinned behavior, and the local-build dev workflow.

- [ ] **Step 5.1: Edit `README.md`**

Find the section titled `## What you get (default)` (the lean default sidecar). Replace it with:

```markdown
## What you get (default)

- A `claude` sidecar built from a **pre-built multi-arch base image**
  (`ghcr.io/makraz/ddev-claude-base:<version>`, published from this repo)
  containing:
  - Claude Code CLI (native binary, installed at image build time)
  - git, bash, sudo, curl, ca-certificates
  - iptables/ipset/dnsmasq/dnsutils/iproute2 for the firewall
  - The unprivileged `claude` user (uid 1000) with a NOPASSWD sudoers entry
    scoped to `/usr/local/bin/init-firewall.sh`
- An **outbound firewall** (default-DROP policy) that only allows:
  - `github.com`, `api.github.com`
  - `anthropic.com`, `claude.ai`
  - The DDEV internal network (so the agent can reach `web`, `db`, …)
- A `ddev claude` host command with subcommands (`safe`, `shell`, `exec`,
  `rebuild`, `help`).
- Persistent Claude Code auth + settings at `.ddev/.claude/` (gitignored).

The image tag is pinned to the addon version 1:1. Installing
`ddev-claude@v0.3.0` always pulls `ddev-claude-base:v0.3.0` — no floating
`:latest`, no surprise upgrades. The exact Claude Code build baked into a
given image is recorded in the OCI label `io.makraz.ddev-claude.claude-version`
(visible via `docker inspect`).
```

- [ ] **Step 5.2: Add a developer note section**

After the `## Cookbook (escape hatch)` section, before `## Verifying the sandbox`, add a new section titled `## Developing the addon`:

```markdown
## Developing the addon

The published image (`ghcr.io/makraz/ddev-claude-base:<version>`) is built
from `image/Dockerfile` by `.github/workflows/publish-image.yml` on every
git tag push. To iterate on `image/Dockerfile` without publishing:

```bash
# Build locally with the tag the addon expects:
TAG=$(grep -m1 'FROM ghcr.io/.*/ddev-claude-base:' .ddev/claude/Dockerfile.base | sed 's|.*:||')
docker build -t "ghcr.io/makraz/ddev-claude-base:${TAG}" image/

# Now ddev restart picks up your local image (Docker's default `missing`
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
```

Use a HEREDOC of triple-backticks if your editor mangles nested fences — keep
the inner shell blocks intact.

- [ ] **Step 5.3: Update the architecture diagram**

Find the `## Architecture` section. Replace the existing ASCII diagram with:

```
┌─ Host ───────────────────────────────────────────────────────────────┐
│                                                                      │
│   .github/workflows/publish-image.yml ─► ghcr.io/.../ddev-claude-    │
│        (on tag push)                       base:<version>            │
│                                                       │              │
│   .ddev/claude.yaml ──► build-image.sh ──► .ddev/claude/Dockerfile   │
│                          (pre-start hook)             │              │
│                                                       ▼              │
│   ddev claude ──► docker exec ──► ┌─ claude sidecar ──────────────┐  │
│                                   │  FROM ddev-claude-base:<ver>  │  │
│                                   │  + init-firewall.sh           │  │
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

- [ ] **Step 5.4: Commit**

Run:
```
git add README.md
git commit -m "docs: README updates for pre-built image"
```

---

## Task 6: End-to-end smoke + final verification

**Files:** none changed.

- [ ] **Step 6.1: Run the unit tests one more time**

Run:
```
bats tests/build-image.bats
```
Expected: `12 tests, 0 failures`. If anything fails, stop and fix before continuing.

- [ ] **Step 6.2: Run the install integration test**

The base image was already built locally in Task 1. The integration test does a `ddev restart` which will use the cached local image (no GHCR fetch needed).

Run:
```
bats tests/test.bats --filter 'install: addon installs and sidecar comes up'
```
Expected: passes. If it fails with "manifest unknown" or similar, the local image's tag does not match what `Dockerfile.base` expects — re-run Step 1.2 with the correct tag (`v0.3.0-beta.1`).

If you don't have a working ddev locally, you may skip this step but note it in the commit log; CI will run the full integration suite on the PR.

- [ ] **Step 6.3: (Optional, slow) Run the full integration suite**

Run:
```
bats tests/test.bats
```
Expected: all 10 tests pass. Skip if local env is missing ddev/docker; CI will validate.

- [ ] **Step 6.4: Verify the new workflow file is valid**

Run:
```
python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/publish-image.yml"))' && \
python3 -c 'import yaml; yaml.safe_load(open(".github/workflows/tests.yml"))' && \
echo "both workflows OK"
```
Expected: `both workflows OK`.

- [ ] **Step 6.5: Confirm branch state**

Run:
```
git log --oneline main..HEAD
```
Expected: ~5 commits on `feat/prebuilt-image`:
1. `feat: image source for ddev-claude-base`
2. `docs: image/README describing the base image`
3. `feat: thin Dockerfile.base wrapper + CI local image build`
4. `ci: publish-image workflow for multi-arch GHCR build on tag push`
5. `docs: README updates for pre-built image`

- [ ] **Step 6.6: Push the branch (when ready)**

Run:
```
git push -u origin feat/prebuilt-image
```
Expected: push succeeds. CI starts on the PR (when opened). The "Build base image locally" step in `tests.yml` should pick up the new image and the bats integration tests should pass.

**Do NOT push a `v0.3.0-beta.1` tag yet.** Tag push triggers the publish-image workflow which writes to GHCR — only do this after the branch merges to `main`.

---

## Release sequence (after this plan is merged)

The plan ends here; the release is a one-time human-driven step on `main`:

```bash
git checkout main
git pull
git tag v0.3.0-beta.1
git push origin v0.3.0-beta.1
# `publish-image.yml` fires, builds + pushes ghcr.io/.../ddev-claude-base:v0.3.0-beta.1
# Wait ~5 minutes.

gh release create v0.3.0-beta.1 --prerelease \
  --title "v0.3.0-beta.1 — pre-built base image" \
  --notes-file release-notes.md
```

(`release-notes.md` is whatever you want the user-facing changelog to say; the spec's "What's new in v0.3.0" content is a good seed.)

---

## Definition of done

- 5 commits on `feat/prebuilt-image`, pushed to origin.
- `tests/build-image.bats` green locally + in CI.
- `tests/test.bats` green in CI (local validation optional).
- `image/Dockerfile` builds for `linux/amd64` locally and produces a working sidecar with `claude --version` succeeding.
- `claude/Dockerfile.base` is the ~14-line thin wrapper.
- `.github/workflows/publish-image.yml` exists and yaml-parses cleanly.
- `.github/workflows/tests.yml` has the new local-build step.
- README has the pre-built image section, the dev workflow section, and the refreshed architecture diagram.
- Once tagged + released as `v0.3.0-beta.1`, `ddev add-on get makraz/ddev-claude@v0.3.0-beta.1` in a fresh test project completes a `ddev restart` in roughly 20 s (pull + thin wrapper build).
