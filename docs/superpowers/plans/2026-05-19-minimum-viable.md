# Minimum Viable ddev-claude Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip `ddev-claude` to a minimum-viable core (Claude Code + firewall on `debian:bookworm-slim`), add a build-time extras catalog driven by `.ddev/claude.yaml`, migrate state to `.ddev/.claude/`, and ship a subcommand-based `ddev claude` CLI — preserving the existing firewall + filesystem isolation guarantees.

**Architecture:** Sidecar image is assembled from `claude/Dockerfile.base` + zero-or-more selected `claude/extras/<name>.fragment` files + an optional project-local `.ddev/claude.local/Dockerfile.fragment`, by a host-side script `build-image.sh` that runs on the `pre-start` DDEV hook. Runtime firewall reads its allow-list additions from `/var/www/html/.ddev/claude/extra-domains.list` (build-generated) plus the existing legacy fallbacks.

**Tech Stack:** Bash, awk, Docker, docker-compose, DDEV (>= 1.24), bats-core, Debian bookworm-slim, Claude Code native installer.

**Reference spec:** `docs/superpowers/specs/2026-05-19-minimum-viable-design.md`.

---

## File structure (target end-state)

```
ddev-claude/
├── claude/
│   ├── Dockerfile.base               # NEW: lean template with {{EXTRAS}} marker
│   ├── build-image.sh                # NEW: host-side assembler
│   ├── init-firewall.sh              # MODIFIED: trim defaults, read project extra-domains.list
│   └── extras/
│       ├── php.fragment              # NEW: Dockerfile snippet (PHP 8.5 + Composer)
│       └── php.domains               # NEW: packagist.org, repo.packagist.org
├── commands/host/claude              # MODIFIED: subcommand router
├── config.claude.yaml                # NEW: pre-start hook
├── docker-compose.claude.yaml        # MODIFIED: bind-mount state dir; drop named volumes
├── install.yaml                      # MODIFIED: project_files, pre_install bootstrap, removal_actions
├── README.md                         # MODIFIED: new architecture, config, cookbook, commands
├── tests/
│   ├── test.bats                     # MODIFIED: integration tests (ddev start required)
│   └── build-image.bats              # NEW: unit tests for build-image.sh (no ddev needed)
└── (DELETED)
    └── claude/Dockerfile             # OLD monolithic Dockerfile
```

Each task below builds one or a few of these files and is independently testable. TDD is applied to `build-image.sh` via the new `tests/build-image.bats` unit tests (no ddev required). The Dockerfile.base, fragment, and CLI/compose/install files are verified through `tests/test.bats` integration tests.

---

## Conventions used in this plan

- Working directory for every command is the repo root: `/Users/hamza/Workspace/ddev-claude` (unless `cd` is shown).
- `bats` means `bats-core`. Install on macOS via `brew install bats-core`; on Linux via the OS package manager.
- "Run" lines show exact commands. Expected output is shown as `Expected: ...`.
- Commits use Conventional Commit prefixes (`feat:`, `fix:`, `chore:`, `docs:`, `test:`, `refactor:`).
- **Never** add `Co-Authored-By: Claude` (per project CLAUDE.md).

---

## Task 1: Replace `claude/Dockerfile` with the lean `claude/Dockerfile.base`

**Files:**
- Delete: `claude/Dockerfile`
- Create: `claude/Dockerfile.base`

Old Dockerfile is the monolithic 1.5 GB image. New base is `debian:bookworm-slim` + 10 packages + Claude Code via the official native installer. Replaces, not extends.

- [ ] **Step 1.1: Delete the old Dockerfile**

Run:
```
git rm claude/Dockerfile
```
Expected: `rm 'claude/Dockerfile'`. The file is removed from the working tree and staged for deletion.

- [ ] **Step 1.2: Create `claude/Dockerfile.base`**

Write the file with exactly this content:

```dockerfile
#ddev-generated
# ---------------------------------------------------------------------------
# Claude Code sandbox — sidecar container for ddev (minimum-viable base).
#
# This file is the TEMPLATE. The actual Dockerfile used by docker-compose is
# generated at build time by build-image.sh, which inlines selected extras
# (from claude/extras/) plus an optional project-local Dockerfile fragment
# (.ddev/claude.local/Dockerfile.fragment) at the {{EXTRAS}} marker below.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Core packages — nothing else by default. Anything project-specific (PHP,
# composer, gh, playwright, …) is added via the extras catalog or the
# escape hatch.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Non-root user (uid 1000) — agent runs here, never as root.
# ---------------------------------------------------------------------------
ARG USERNAME=claude
ARG USER_UID=1000
RUN groupadd --gid $USER_UID $USERNAME \
 && useradd  --uid $USER_UID --gid $USER_UID -m -s /bin/bash $USERNAME \
 && echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
      > /etc/sudoers.d/claude-firewall \
 && chmod 0440 /etc/sudoers.d/claude-firewall

# ---------------------------------------------------------------------------
# Firewall script — root-owned, never modified at runtime.
# ---------------------------------------------------------------------------
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
RUN chmod 0755 /usr/local/bin/init-firewall.sh

# ---- EXTRAS INJECTION POINT ----
# build-image.sh replaces the line `# {{EXTRAS}}` below with the concatenated
# contents of every selected claude/extras/<name>.fragment, followed by
# .ddev/claude.local/Dockerfile.fragment if it exists. Fragments execute as
# root (the current USER context here). If a fragment switches USER, it must
# restore `USER root` before its end.
# {{EXTRAS}}
# --------------------------------

# ---------------------------------------------------------------------------
# Install Claude Code as the unprivileged claude user, via the official
# native installer. No Node.js required.
# ---------------------------------------------------------------------------
USER claude
WORKDIR /home/claude
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/claude/.local/bin:${PATH}"

WORKDIR /var/www/html
```

- [ ] **Step 1.3: Smoke-build the base image directly**

This validates the Dockerfile.base alone (with no extras processing) actually produces a working sidecar. The `# {{EXTRAS}}` line is a comment, so Docker treats it as a no-op.

We need `init-firewall.sh` in the build context. It exists (we'll modify it in Task 4). For now, smoke-build using a temp copy of the Dockerfile renamed to `Dockerfile`:

Run:
```
cp claude/Dockerfile.base claude/Dockerfile.smoketest && \
  docker build -t ddev-claude-smoke -f claude/Dockerfile.smoketest claude/ && \
  rm claude/Dockerfile.smoketest
```
Expected: build succeeds; image `ddev-claude-smoke` exists. Final size should be ~300-400 MB (debian-slim + apt packages + claude binary). If build fails on `curl ... claude.ai/install.sh`, troubleshoot the installer URL; do not proceed.

- [ ] **Step 1.4: Verify the smoke image actually runs claude**

Run:
```
docker run --rm ddev-claude-smoke /home/claude/.local/bin/claude --version
```
Expected: claude prints a version string (any version is fine). If it prints "command not found", the installer didn't land the binary where we expect — read the installer output from Step 1.3 and adjust the `PATH` env in `Dockerfile.base` accordingly.

- [ ] **Step 1.5: Clean up the smoke image**

Run:
```
docker rmi ddev-claude-smoke
```
Expected: untagged + removed.

- [ ] **Step 1.6: Commit**

Run:
```
git add -A claude/
git commit -m "feat: replace monolithic Dockerfile with lean Dockerfile.base

Swaps node:22-bookworm for debian:bookworm-slim. Installs Claude Code
via the official native installer (no Node.js). All PHP, Composer,
Playwright, Chromium, MCPs, and gh removed from defaults — they move
to opt-in extras in subsequent commits."
```

---

## Task 2: Create the `php` extra (fragment + domains)

**Files:**
- Create: `claude/extras/php.fragment`
- Create: `claude/extras/php.domains`

- [ ] **Step 2.1: Create `claude/extras/` directory and the fragment**

The fragment must restore `USER root` at the start in case anything subsequent runs after another fragment that left a non-root USER. (Belt-and-braces — at the {{EXTRAS}} marker the current USER is already root from Dockerfile.base, but multiple fragments could change that.) Build deps are installed and purged in a single RUN to keep the layer small.

Write `claude/extras/php.fragment`:
```dockerfile
#ddev-generated
# Extra: php — PHP 8.5 CLI + Composer + common extensions.
# Runtime allow-list contributions: see php.domains.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      gnupg \
      lsb-release \
      libzip-dev \
      libicu-dev \
      libxml2-dev \
      libpng-dev \
      libjpeg-dev \
      libfreetype6-dev \
      libonig-dev \
      libxslt-dev \
 && curl -fsSL https://packages.sury.org/php/apt.gpg \
      -o /etc/apt/trusted.gpg.d/sury-php.gpg \
 && echo "deb https://packages.sury.org/php/ bookworm main" \
      > /etc/apt/sources.list.d/sury-php.list \
 && apt-get update && apt-get install -y --no-install-recommends \
      php8.5-cli \
      php8.5-bcmath \
      php8.5-curl \
      php8.5-gd \
      php8.5-intl \
      php8.5-mbstring \
      php8.5-mysql \
      php8.5-soap \
      php8.5-xml \
      php8.5-xsl \
      php8.5-zip \
 && update-alternatives --set php /usr/bin/php8.5 \
 && apt-get purge -y --auto-remove \
      libzip-dev libicu-dev libxml2-dev libpng-dev libjpeg-dev \
      libfreetype6-dev libonig-dev libxslt-dev gnupg lsb-release \
 && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
```

- [ ] **Step 2.2: Create `claude/extras/php.domains`**

Write `claude/extras/php.domains`:
```
# Runtime domains for the php extra (read by init-firewall.sh).
packagist.org
repo.packagist.org
```

- [ ] **Step 2.3: Commit**

Run:
```
git add claude/extras/php.fragment claude/extras/php.domains
git commit -m "feat: add php extra (PHP 8.5 + Composer + ext)

First entry in the catalog. Provides PHP 8.5 CLI, Composer, and the
extensions previously baked into the core image. Runtime allow-list
contributions (packagist.org, repo.packagist.org) live in php.domains."
```

---

## Task 3: Build-image.sh — Part A: YAML parser (TDD)

**Files:**
- Create: `tests/build-image.bats`
- Create: `claude/build-image.sh`

We test the YAML parser through the script's exit code + the resolved variables it writes to a debug file. The bats tests for `build-image.sh` do not require `ddev`; they run the script directly against fixture files in a temp dir.

- [ ] **Step 3.1: Bootstrap `tests/build-image.bats` with the parser tests**

Write `tests/build-image.bats`:
```bash
#!/usr/bin/env bats

# Unit tests for claude/build-image.sh.
# These run the script directly against fixtures in $BATS_TMPDIR; no ddev/docker.

setup() {
  export REPO="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )/.."
  export SCRIPT="$REPO/claude/build-image.sh"

  # Build a fake project dir that mirrors the .ddev/claude/ layout build-image.sh expects.
  export PROJ="$(mktemp -d)"
  mkdir -p "$PROJ/.ddev/claude/extras"
  cp "$REPO/claude/Dockerfile.base"        "$PROJ/.ddev/claude/Dockerfile.base"
  cp "$REPO/claude/extras/php.fragment"    "$PROJ/.ddev/claude/extras/php.fragment"
  cp "$REPO/claude/extras/php.domains"     "$PROJ/.ddev/claude/extras/php.domains"
  cp "$SCRIPT"                             "$PROJ/.ddev/claude/build-image.sh"
  chmod +x "$PROJ/.ddev/claude/build-image.sh"
}

teardown() {
  rm -rf "$PROJ"
}

@test "parser: empty config (no .ddev/claude.yaml) → no extras selected" {
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.ddev/claude/Dockerfile" ]
  # No fragment content should be inlined — the marker line is replaced with nothing.
  run grep -F '# {{EXTRAS}}' "$PROJ/.ddev/claude/Dockerfile"
  [ "$status" -ne 0 ]
  # PHP install string should not be present in the generated Dockerfile.
  run grep -F 'packages.sury.org' "$PROJ/.ddev/claude/Dockerfile"
  [ "$status" -ne 0 ]
}

@test "parser: extras: [php] → php fragment inlined" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extras:
  - php
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  run grep -F 'packages.sury.org' "$PROJ/.ddev/claude/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "parser: comments and blank lines in claude.yaml are ignored" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
# top comment

extras:
  # a comment inside the list
  - php

YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
}

@test "parser: unknown extra → exits non-zero with clear error" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extras:
  - bogus
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown extra 'bogus'" ]]
}

@test "parser: unknown top-level key → exits non-zero with clear error" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extras:
  - php
unexpected_key:
  - whatever
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown key 'unexpected_key'" ]]
}

@test "parser: extra_allowed_domains parsed and emitted into extra-domains.list" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extra_allowed_domains:
  - sentry.io
  - api.stripe.com
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.ddev/claude/extra-domains.list" ]
  run grep -Fx 'sentry.io' "$PROJ/.ddev/claude/extra-domains.list"
  [ "$status" -eq 0 ]
  run grep -Fx 'api.stripe.com' "$PROJ/.ddev/claude/extra-domains.list"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 3.2: Run the new bats file — every test should fail (build-image.sh doesn't exist yet)**

Run:
```
bats tests/build-image.bats
```
Expected: 6 tests fail, all reporting `No such file or directory` or similar (the script doesn't exist yet).

- [ ] **Step 3.3: Create the script with the YAML parser**

Write `claude/build-image.sh`:
```bash
#!/usr/bin/env bash
#ddev-generated
#
# build-image.sh — assemble the per-project sidecar Dockerfile.
#
# Reads:
#   - .ddev/claude.yaml             (per-project config; extras + extra_allowed_domains)
#   - .ddev/claude/Dockerfile.base  (template with {{EXTRAS}} marker)
#   - .ddev/claude/extras/*.fragment, *.domains, *.requires
#   - .ddev/claude.local/Dockerfile.fragment (optional escape hatch)
#   - .ddev/claude.local/extra-domains.list  (optional escape hatch)
#
# Writes:
#   - .ddev/claude/Dockerfile           (used by docker-compose)
#   - .ddev/claude/extra-domains.list   (read by init-firewall.sh inside the sidecar)
#   - .ddev/claude/.build-stamp         (input-hash → skip work when unchanged)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_DIR="$SCRIPT_DIR"
DDEV_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$DDEV_DIR/claude.yaml"
LOCAL_DIR="$DDEV_DIR/claude.local"
EXTRAS_DIR="$ADDON_DIR/extras"
BASE_DOCKERFILE="$ADDON_DIR/Dockerfile.base"
OUT_DOCKERFILE="$ADDON_DIR/Dockerfile"
OUT_DOMAINS="$ADDON_DIR/extra-domains.list"
STAMP="$ADDON_DIR/.build-stamp"

die() { echo "build-image: error: $*" >&2; exit 1; }
log() { echo "build-image: $*"; }

[[ -f "$BASE_DOCKERFILE" ]] || die "missing $BASE_DOCKERFILE"

# Globals populated by parse_claude_yaml.
EXTRAS=()
EXTRA_DOMAINS_LIST=()

parse_claude_yaml() {
  local file="$1"
  [[ -f "$file" ]] || return 0   # absent = empty config
  local current_key=""
  local line_no=0 raw line key val

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_no=$((line_no + 1))
    line="${raw%%#*}"
    # trim trailing whitespace
    while [[ "$line" =~ [[:space:]]$ ]]; do line="${line%[[:space:]]}"; done
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^([a-zA-Z_]+):[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[1]}"
      case "$key" in
        extras)               current_key=extras ;;
        extra_allowed_domains) current_key=extra_domains ;;
        *) die "unknown key '$key' in $file (line $line_no; allowed: extras, extra_allowed_domains)" ;;
      esac
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]+-[[:space:]]*(.+)$ ]]; then
      val="${BASH_REMATCH[1]}"
      val="${val#\"}"; val="${val%\"}"
      val="${val#\'}"; val="${val%\'}"
      case "$current_key" in
        extras)        EXTRAS+=("$val") ;;
        extra_domains) EXTRA_DOMAINS_LIST+=("$val") ;;
        *) die "list item without parent key at line $line_no" ;;
      esac
      continue
    fi

    die "failed to parse $file at line $line_no: '$raw'"
  done < "$file"
}

validate_extras() {
  local available=()
  if [[ -d "$EXTRAS_DIR" ]]; then
    local f
    for f in "$EXTRAS_DIR"/*.fragment; do
      [[ -f "$f" ]] || continue
      available+=("$(basename "$f" .fragment)")
    done
  fi
  local e found a
  for e in "${EXTRAS[@]}"; do
    found=0
    for a in "${available[@]}"; do
      [[ "$a" == "$e" ]] && found=1 && break
    done
    [[ $found -eq 1 ]] || die "unknown extra '$e' (available: ${available[*]:-<none>})"
  done
}

main() {
  parse_claude_yaml "$CONFIG_FILE"
  validate_extras
  # Generation is implemented in Task 4. For Task 3 we exit successfully so
  # the parser-only tests pass; later tasks extend this.
  : > "$OUT_DOCKERFILE"
  : > "$OUT_DOMAINS"
  generate_dockerfile
  generate_domains_list
}

generate_dockerfile() {
  # Concatenate selected fragments + local fragment, then splice into Dockerfile.base
  # replacing the literal `# {{EXTRAS}}` marker line.
  local tmp_frags
  tmp_frags="$(mktemp)"
  trap 'rm -f "$tmp_frags"' RETURN

  local e first=1
  for e in "${EXTRAS[@]}"; do
    [[ $first -eq 0 ]] && echo "" >> "$tmp_frags"
    cat "$EXTRAS_DIR/${e}.fragment" >> "$tmp_frags"
    first=0
  done
  if [[ -f "$LOCAL_DIR/Dockerfile.fragment" ]]; then
    [[ $first -eq 0 ]] && echo "" >> "$tmp_frags"
    cat "$LOCAL_DIR/Dockerfile.fragment" >> "$tmp_frags"
  fi

  awk -v frags="$tmp_frags" '
    /^# \{\{EXTRAS\}\}$/ {
      while ((getline line < frags) > 0) print line
      close(frags)
      next
    }
    { print }
  ' "$BASE_DOCKERFILE" > "$OUT_DOCKERFILE"
}

generate_domains_list() {
  : > "$OUT_DOMAINS"
  local e d
  for e in "${EXTRAS[@]}"; do
    if [[ -f "$EXTRAS_DIR/${e}.domains" ]]; then
      while IFS= read -r d || [[ -n "$d" ]]; do
        d="${d%%#*}"
        d="$(echo "$d" | xargs)"
        [[ -n "$d" ]] && echo "$d" >> "$OUT_DOMAINS"
      done < "$EXTRAS_DIR/${e}.domains"
    fi
  done
  if [[ -f "$LOCAL_DIR/extra-domains.list" ]]; then
    while IFS= read -r d || [[ -n "$d" ]]; do
      d="${d%%#*}"
      d="$(echo "$d" | xargs)"
      [[ -n "$d" ]] && echo "$d" >> "$OUT_DOMAINS"
    done < "$LOCAL_DIR/extra-domains.list"
  fi
  for d in "${EXTRA_DOMAINS_LIST[@]}"; do
    echo "$d" >> "$OUT_DOMAINS"
  done

  # Dedup, preserving first occurrence order.
  awk '!seen[$0]++' "$OUT_DOMAINS" > "${OUT_DOMAINS}.tmp" && mv "${OUT_DOMAINS}.tmp" "$OUT_DOMAINS"
}

main "$@"
```

Then make it executable:
```
chmod +x claude/build-image.sh
```

- [ ] **Step 3.4: Run the parser tests — all 6 must pass**

Run:
```
bats tests/build-image.bats
```
Expected: `6 tests, 0 failures`. If any test fails, fix the parser inline before continuing — do not move to Task 4.

- [ ] **Step 3.5: Commit**

Run:
```
git add tests/build-image.bats claude/build-image.sh
git commit -m "feat: build-image.sh parser + Dockerfile/domains generation

Parses .ddev/claude.yaml (extras + extra_allowed_domains only), validates
extras against claude/extras/, concatenates selected fragments at the
{{EXTRAS}} marker in Dockerfile.base, emits extra-domains.list with the
union of each extra's .domains contributions, .ddev/claude.local
overrides, and per-project extra_allowed_domains."
```

---

## Task 4: Build-image.sh — Part B: `.requires` resolution, local-fragment, and build stamp

**Files:**
- Modify: `claude/build-image.sh`
- Modify: `tests/build-image.bats`

The Task 3 script already wrote the Dockerfile + domains. Task 4 adds the `.requires` topological resolution (for future catalog growth — exercised by a fixture with a fake dependency), the build-stamp no-op, and tests for the escape hatch + `extra_allowed_domains` end-to-end.

- [ ] **Step 4.1: Append the new tests to `tests/build-image.bats`**

Append these tests **at the end of** `tests/build-image.bats` (the existing tests + setup remain):

```bash
@test ".requires: dependent extras pulled in transitively" {
  # Add two fixture extras: alpha (no deps), beta (.requires alpha).
  cat > "$PROJ/.ddev/claude/extras/alpha.fragment" <<'F'
USER root
RUN echo alpha-marker > /tmp/alpha-marker
F
  : > "$PROJ/.ddev/claude/extras/alpha.domains"
  cat > "$PROJ/.ddev/claude/extras/beta.fragment" <<'F'
USER root
RUN echo beta-marker > /tmp/beta-marker
F
  : > "$PROJ/.ddev/claude/extras/beta.domains"
  echo "alpha" > "$PROJ/.ddev/claude/extras/beta.requires"

  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extras:
  - beta
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  # Both markers should appear, with alpha BEFORE beta in the Dockerfile.
  run grep -n alpha-marker "$PROJ/.ddev/claude/Dockerfile"
  [ "$status" -eq 0 ]
  alpha_line="${output%%:*}"
  run grep -n beta-marker "$PROJ/.ddev/claude/Dockerfile"
  [ "$status" -eq 0 ]
  beta_line="${output%%:*}"
  [ "$alpha_line" -lt "$beta_line" ]
}

@test ".requires: cycle detected and reported" {
  cat > "$PROJ/.ddev/claude/extras/loop1.fragment" <<'F'
USER root
F
  cat > "$PROJ/.ddev/claude/extras/loop2.fragment" <<'F'
USER root
F
  echo "loop2" > "$PROJ/.ddev/claude/extras/loop1.requires"
  echo "loop1" > "$PROJ/.ddev/claude/extras/loop2.requires"

  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extras:
  - loop1
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "dependency cycle" ]]
}

@test "escape hatch: .ddev/claude.local/Dockerfile.fragment is appended" {
  mkdir -p "$PROJ/.ddev/claude.local"
  cat > "$PROJ/.ddev/claude.local/Dockerfile.fragment" <<'F'
USER root
RUN echo local-marker > /tmp/local-marker
F
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  run grep -F 'local-marker' "$PROJ/.ddev/claude/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "escape hatch: .ddev/claude.local/extra-domains.list contents merged" {
  mkdir -p "$PROJ/.ddev/claude.local"
  cat > "$PROJ/.ddev/claude.local/extra-domains.list" <<'EOF'
# local domains
example-local.test
EOF
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  run grep -Fx 'example-local.test' "$PROJ/.ddev/claude/extra-domains.list"
  [ "$status" -eq 0 ]
}

@test "build stamp: unchanged inputs → second run is a no-op" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extras:
  - php
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  mtime1="$(stat -f %m "$PROJ/.ddev/claude/Dockerfile" 2>/dev/null || stat -c %Y "$PROJ/.ddev/claude/Dockerfile")"
  sleep 1
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  mtime2="$(stat -f %m "$PROJ/.ddev/claude/Dockerfile" 2>/dev/null || stat -c %Y "$PROJ/.ddev/claude/Dockerfile")"
  [ "$mtime1" = "$mtime2" ]
}

@test "build stamp: changed config → regenerates" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extras:
  - php
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  mtime1="$(stat -f %m "$PROJ/.ddev/claude/Dockerfile" 2>/dev/null || stat -c %Y "$PROJ/.ddev/claude/Dockerfile")"
  sleep 1
  # remove php from extras
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extras: []
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  mtime2="$(stat -f %m "$PROJ/.ddev/claude/Dockerfile" 2>/dev/null || stat -c %Y "$PROJ/.ddev/claude/Dockerfile")"
  [ "$mtime2" -gt "$mtime1" ]
}
```

Note: one of the tests writes `extras: []`. The current parser doesn't handle the empty-list shorthand `[]` — it only handles indented `- item` lines. We must teach the parser to accept `extras: []` and `extra_allowed_domains: []` as legal "empty list". Task 4 adds this.

- [ ] **Step 4.2: Run the new tests — they should fail (features not implemented)**

Run:
```
bats tests/build-image.bats
```
Expected: previous 6 tests pass; new 6 tests fail. Specifically, `.requires`, cycle detection, and build-stamp tests fail. (Escape-hatch tests may already pass from Task 3 code — that's fine.) Confirm at least the `.requires`, cycle, and stamp tests are red.

- [ ] **Step 4.3: Add `.requires` resolver, empty-list parsing, and build-stamp to `build-image.sh`**

Edit `claude/build-image.sh` and make these changes:

**A.** Update the parser to accept the empty-list `[]` shorthand. Replace this block in `parse_claude_yaml`:

```bash
    if [[ "$line" =~ ^([a-zA-Z_]+):[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[1]}"
      case "$key" in
        extras)               current_key=extras ;;
        extra_allowed_domains) current_key=extra_domains ;;
        *) die "unknown key '$key' in $file (line $line_no; allowed: extras, extra_allowed_domains)" ;;
      esac
      continue
    fi
```

with:

```bash
    if [[ "$line" =~ ^([a-zA-Z_]+):[[:space:]]*(\[[[:space:]]*\])?[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[1]}"
      case "$key" in
        extras)               current_key=extras ;;
        extra_allowed_domains) current_key=extra_domains ;;
        *) die "unknown key '$key' in $file (line $line_no; allowed: extras, extra_allowed_domains)" ;;
      esac
      # `key: []` is the empty-list shorthand — no further items; reset current_key
      # so any subsequent indented list items would be detected as a parse error.
      if [[ "${BASH_REMATCH[2]:-}" == *"["* ]]; then
        current_key=""
      fi
      continue
    fi
```

**B.** Add the resolver. Insert this new function above `main`:

```bash
# RESOLVED_EXTRAS is filled in resolution order: dependencies before dependents.
RESOLVED_EXTRAS=()
_VISITING=()
_VISITED=()

_in_array() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

_visit_extra() {
  local name="$1"
  _in_array "$name" "${_VISITED[@]:-}" && return 0
  _in_array "$name" "${_VISITING[@]:-}" && {
    local chain
    chain="$(printf '%s -> ' "${_VISITING[@]}")"
    die "dependency cycle in extras: ${chain}${name}"
  }
  _VISITING+=("$name")

  local req_file="$EXTRAS_DIR/${name}.requires"
  if [[ -f "$req_file" ]]; then
    local dep
    while IFS= read -r dep || [[ -n "$dep" ]]; do
      dep="${dep%%#*}"
      dep="$(echo "$dep" | xargs)"
      [[ -z "$dep" ]] && continue
      _in_array "$dep" $(ls "$EXTRAS_DIR" 2>/dev/null | sed -n 's/\.fragment$//p') \
        || die "extra '$name' requires unknown extra '$dep'"
      _visit_extra "$dep"
    done < "$req_file"
  fi

  # pop from VISITING (last element), push to VISITED and RESOLVED_EXTRAS
  unset '_VISITING[${#_VISITING[@]}-1]'
  _VISITING=("${_VISITING[@]}")
  _VISITED+=("$name")
  RESOLVED_EXTRAS+=("$name")
}

resolve_extras() {
  RESOLVED_EXTRAS=()
  _VISITING=()
  _VISITED=()
  local e
  for e in "${EXTRAS[@]:-}"; do
    _visit_extra "$e"
  done
}
```

**C.** Change `main` to call the resolver and to use `RESOLVED_EXTRAS` everywhere the script currently uses `EXTRAS`:

Replace `main()` with:

```bash
main() {
  parse_claude_yaml "$CONFIG_FILE"
  validate_extras
  resolve_extras

  if stamp_matches; then
    log "inputs unchanged; skipping regeneration."
    exit 0
  fi

  generate_dockerfile
  generate_domains_list
  write_stamp

  log "wrote $OUT_DOCKERFILE and $OUT_DOMAINS (extras: ${RESOLVED_EXTRAS[*]:-<none>})"
}
```

Replace `generate_dockerfile`'s `for e in "${EXTRAS[@]}"` with `for e in "${RESOLVED_EXTRAS[@]:-}"`. Replace `generate_domains_list`'s same loop with `for e in "${RESOLVED_EXTRAS[@]:-}"`.

**D.** Add the stamp helpers. Insert above `main`:

```bash
compute_stamp() {
  {
    printf '%s\n' "resolved:${RESOLVED_EXTRAS[*]:-}"
    printf '%s\n' "domains:${EXTRA_DOMAINS_LIST[*]:-}"
    local e
    for e in "${RESOLVED_EXTRAS[@]:-}"; do
      printf 'fragment:%s\n' "$e"
      sha256sum "$EXTRAS_DIR/${e}.fragment" 2>/dev/null || shasum -a 256 "$EXTRAS_DIR/${e}.fragment"
      if [[ -f "$EXTRAS_DIR/${e}.domains" ]]; then
        sha256sum "$EXTRAS_DIR/${e}.domains" 2>/dev/null || shasum -a 256 "$EXTRAS_DIR/${e}.domains"
      fi
    done
    sha256sum "$BASE_DOCKERFILE" 2>/dev/null || shasum -a 256 "$BASE_DOCKERFILE"
    if [[ -f "$LOCAL_DIR/Dockerfile.fragment" ]]; then
      sha256sum "$LOCAL_DIR/Dockerfile.fragment" 2>/dev/null || shasum -a 256 "$LOCAL_DIR/Dockerfile.fragment"
    fi
    if [[ -f "$LOCAL_DIR/extra-domains.list" ]]; then
      sha256sum "$LOCAL_DIR/extra-domains.list" 2>/dev/null || shasum -a 256 "$LOCAL_DIR/extra-domains.list"
    fi
  } | sha256sum 2>/dev/null | awk '{print $1}' || shasum -a 256 | awk '{print $1}'
}

stamp_matches() {
  [[ -f "$STAMP" ]] || return 1
  [[ -f "$OUT_DOCKERFILE" ]] || return 1
  [[ -f "$OUT_DOMAINS" ]] || return 1
  local now then
  now="$(compute_stamp)"
  then="$(cat "$STAMP")"
  [[ "$now" == "$then" ]]
}

write_stamp() {
  compute_stamp > "$STAMP"
}
```

- [ ] **Step 4.4: Run all `build-image.bats` tests**

Run:
```
bats tests/build-image.bats
```
Expected: all 12 tests pass (`12 tests, 0 failures`). If any fail, debug inline before continuing.

- [ ] **Step 4.5: Commit**

Run:
```
git add tests/build-image.bats claude/build-image.sh
git commit -m "feat: .requires resolution, empty-list parsing, build stamp

Adds topological resolution of extras' .requires files with cycle
detection, parsing of the YAML empty-list shorthand (extras: []),
and a sha256 build-stamp that makes repeated invocations no-op when
no inputs changed."
```

---

## Task 5: Update `claude/init-firewall.sh`

**Files:**
- Modify: `claude/init-firewall.sh`

Two changes: trim `DEFAULT_DOMAINS` and read the build-generated `extra-domains.list` from `/var/www/html/.ddev/claude/`.

- [ ] **Step 5.1: Trim `DEFAULT_DOMAINS`**

Edit `claude/init-firewall.sh`. Find this block:

```bash
DEFAULT_DOMAINS=(
  "github.com"
  "api.github.com"
  "anthropic.com"
  "claude.ai"
  "registry.npmjs.org"
  "packagist.org"
  "repo.packagist.org"
  "storage.googleapis.com"
)
```

Replace with:

```bash
DEFAULT_DOMAINS=(
  "github.com"
  "api.github.com"
  "anthropic.com"
  "claude.ai"
)
```

- [ ] **Step 5.2: Add the build-generated allow-list reader**

Find this block:

```bash
EXTRA_DOMAINS=()
EXTRA_FILE="/etc/firewall/extra-domains.list"
if [[ -f "$EXTRA_FILE" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -n "$line" ]] && EXTRA_DOMAINS+=("$line")
  done < "$EXTRA_FILE"
fi
if [[ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_DOMAINS+=( ${EXTRA_ALLOWED_DOMAINS} )
fi
```

Replace with:

```bash
EXTRA_DOMAINS=()
EXTRA_FILES=(
  "/var/www/html/.ddev/claude/extra-domains.list"   # build-generated
  "/etc/firewall/extra-domains.list"                # legacy fallback
)
for EXTRA_FILE in "${EXTRA_FILES[@]}"; do
  [[ -f "$EXTRA_FILE" ]] || continue
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -n "$line" ]] && EXTRA_DOMAINS+=("$line")
  done < "$EXTRA_FILE"
done
if [[ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_DOMAINS+=( ${EXTRA_ALLOWED_DOMAINS} )
fi
```

- [ ] **Step 5.3: Manually smoke-test the script's syntax**

Run:
```
bash -n claude/init-firewall.sh
```
Expected: no output, exit code 0 (syntactically valid).

- [ ] **Step 5.4: Commit**

Run:
```
git add claude/init-firewall.sh
git commit -m "feat: firewall reads project-local extra-domains.list

Trims DEFAULT_DOMAINS to just github/anthropic/claude.ai (npm,
packagist, storage.googleapis.com are now contributed by extras).
Reads /var/www/html/.ddev/claude/extra-domains.list at runtime so
build-image.sh's output extends the allow-list automatically."
```

---

## Task 6: Update `docker-compose.claude.yaml` (state-dir bind-mount)

**Files:**
- Modify: `docker-compose.claude.yaml`

Replace the two named volumes with a single bind-mount of `.ddev/.claude/`.

- [ ] **Step 6.1: Edit `docker-compose.claude.yaml`**

Replace the entire `volumes:` line under `services.claude:` (the block containing `../:/var/www/html` and the two named-volume mounts) plus the top-level `volumes:` block at the bottom of the file. Final content:

```yaml
#ddev-generated
# ---------------------------------------------------------------------------
# ddev-claude — sidecar service definition.
#
# Adds a `claude` container alongside the standard ddev `web` service.
# The container starts with `sleep infinity`; the actual Claude Code
# session is launched on demand by `ddev claude`.
# ---------------------------------------------------------------------------
services:
    claude:
        build:
            context: ./claude
        container_name: ddev-${DDEV_SITENAME}-claude
        working_dir: /var/www/html
        volumes:
            - ../:/var/www/html
            # State (auth, settings, history) lives in the project tree at
            # .ddev/.claude/ — visible/inspectable from the host. Bootstrap
            # is done in install.yaml's pre_install_actions.
            - ../.ddev/.claude:/home/claude/.claude
            - ../.ddev/.claude/bash_history.d:/home/claude/.bash_history.d
        environment:
            - ANTHROPIC_API_KEY
            - PLAYWRIGHT_BASE_URL=https://web
            - CLAUDE_CONFIG_DIR=/home/claude/.claude
            - GITHUB_PERSONAL_ACCESS_TOKEN
            - GH_TOKEN=${GITHUB_PERSONAL_ACCESS_TOKEN:-}
            - EXTRA_ALLOWED_DOMAINS
        cap_add:
            - NET_ADMIN
            - NET_RAW
        labels:
            com.ddev.site-name: ${DDEV_SITENAME}
            com.ddev.approot: $DDEV_APPROOT
        depends_on:
            - web
        networks:
            - default
        entrypoint: sleep infinity
```

Note: the top-level `volumes:` block (with `claude-config:` and `claude-history:`) is deleted entirely.

- [ ] **Step 6.2: Validate compose syntax**

Run:
```
docker compose -f docker-compose.claude.yaml config >/dev/null
```
Expected: no output. If it errors with "no such service: web" or similar, that's expected (this file is a fragment merged by DDEV; it isn't standalone). What we want to confirm is YAML well-formedness — a syntax error would be reported as a yaml parse error. If you see "yaml: line N", fix it.

- [ ] **Step 6.3: Commit**

Run:
```
git add docker-compose.claude.yaml
git commit -m "feat: bind-mount .ddev/.claude/ for state, drop named volumes

Replaces the claude-config and claude-history named volumes with a
single bind-mount of .ddev/.claude/. State (auth tokens, settings,
bash history) now lives in the project tree, visible from the host
and trivially wipeable with rm -rf."
```

---

## Task 7: Create `config.claude.yaml` (pre-start hook)

**Files:**
- Create: `config.claude.yaml`

This is the DDEV addon config file that installs the pre-start hook into the consumer project's effective config.

- [ ] **Step 7.1: Create the file**

Write `config.claude.yaml`:
```yaml
#ddev-generated
# Hook configuration installed by the ddev-claude addon.
# The pre-start hook regenerates .ddev/claude/Dockerfile from
# .ddev/claude/Dockerfile.base + selected extras every time DDEV starts.
hooks:
  pre-start:
    - exec-host: ".ddev/claude/build-image.sh"
```

- [ ] **Step 7.2: Commit**

Run:
```
git add config.claude.yaml
git commit -m "feat: ship pre-start hook for build-image.sh

DDEV merges this addon config into the project's effective config at
install time. The hook ensures .ddev/claude/Dockerfile is always in
sync with .ddev/claude.yaml before docker-compose builds the sidecar."
```

---

## Task 8: Rewrite `commands/host/claude` (subcommand router)

**Files:**
- Modify: `commands/host/claude`

- [ ] **Step 8.1: Replace the entire file**

Write `commands/host/claude`:
```bash
#!/usr/bin/env bash
#ddev-generated
## Description: Run Claude Code inside the sandboxed sidecar container (YOLO mode)
## Usage: claude [subcommand|extra args]
## Example: ddev claude
## Example: ddev claude safe
## Example: ddev claude shell
## Example: ddev claude exec composer install
## Example: ddev claude rebuild
## Example: ddev claude help
## Example: ddev claude --resume
##
## Subcommands:
##   safe              Launch without --dangerously-skip-permissions
##   shell             Drop into bash inside the sidecar
##   exec <cmd> ...    Run one command in the sidecar non-interactively
##   rebuild           Regenerate .ddev/claude/Dockerfile from .ddev/claude.yaml
##   help              Print this help
##
## Anything else (including flags like --resume) is passed through to the
## claude CLI unchanged.
##
## Back-compat: CLAUDE_SAFE=1 ddev claude still works.

set -euo pipefail

CONTAINER="ddev-${DDEV_SITENAME}-claude"

ensure_running() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "error: sidecar container '$CONTAINER' is not running" >&2
    echo "hint:  run 'ddev start' to bring it up" >&2
    exit 1
  fi
}

ensure_firewall() {
  docker exec "$CONTAINER" sudo /usr/local/bin/init-firewall.sh
}

launch_claude() {
  ensure_running
  ensure_firewall
  local args=()
  if [[ "${CLAUDE_SAFE:-0}" != "1" ]]; then
    args+=(--dangerously-skip-permissions)
  fi
  exec docker exec -it \
    --user claude \
    --workdir /var/www/html \
    "$CONTAINER" \
    claude "${args[@]}" "$@"
}

rebuild_image() {
  bash "${DDEV_APPROOT}/.ddev/claude/build-image.sh"
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
  ddev claude <other args>     Pass through to the claude CLI (e.g. --resume).

Environment:
  CLAUDE_SAFE=1                Opt out of YOLO mode for this invocation.
  EXTRA_ALLOWED_DOMAINS=...    Space-separated extra outbound domains.
HELP
}

case "${1:-}" in
  safe)
    shift
    CLAUDE_SAFE=1 launch_claude "$@"
    ;;
  shell)
    shift
    ensure_running
    ensure_firewall
    exec docker exec -it --user claude --workdir /var/www/html "$CONTAINER" bash "$@"
    ;;
  exec)
    shift
    ensure_running
    ensure_firewall
    exec docker exec -i --user claude --workdir /var/www/html "$CONTAINER" "$@"
    ;;
  rebuild)
    shift
    rebuild_image
    exit 0
    ;;
  help)
    show_help
    exit 0
    ;;
  *)
    launch_claude "$@"
    ;;
esac
```

- [ ] **Step 8.2: Validate the script syntactically**

Run:
```
bash -n commands/host/claude
```
Expected: no output, exit 0.

- [ ] **Step 8.3: Commit**

Run:
```
git add commands/host/claude
git commit -m "feat: subcommand router for ddev claude

Adds safe / shell / exec / rebuild / help subcommands. Anything else
(flags, positional args) is passed through to the claude CLI as
before. CLAUDE_SAFE=1 env var still works for back-compat."
```

---

## Task 9: Update `install.yaml`

**Files:**
- Modify: `install.yaml`

- [ ] **Step 9.1: Replace the entire file**

Write `install.yaml`:
```yaml
# ddev-generated
#
# Install manifest for ddev-claude.
# Spec: https://ddev.readthedocs.io/en/stable/users/extend/additional-services/

name: claude

ddev_version_constraint: '>= v1.24.0'

pre_install_actions:
  - |
    #ddev-description:Sandboxed Claude Code CLI with outbound firewall and YOLO mode
  - |
    echo "Installing ddev-claude..."
    echo "Architecture: $(uname -m)"
  - |
    # Bootstrap the project-local state directory.
    set -e
    mkdir -p .ddev/.claude/bash_history.d
    # Try to align ownership with the in-container uid 1000. Best-effort:
    # may fail on hosts where the user doesn't have permission to chown.
    chown -R 1000:1000 .ddev/.claude 2>/dev/null || true

    # Ensure .ddev/.gitignore excludes the state dir and the escape hatch.
    touch .ddev/.gitignore
    for entry in '/.claude/' '/claude.local/' '/claude/Dockerfile' '/claude/extra-domains.list' '/claude/.build-stamp'; do
      grep -qxF "$entry" .ddev/.gitignore || echo "$entry" >> .ddev/.gitignore
    done

project_files:
  - docker-compose.claude.yaml
  - config.claude.yaml
  - claude/Dockerfile.base
  - claude/build-image.sh
  - claude/init-firewall.sh
  - claude/extras/php.fragment
  - claude/extras/php.domains
  - commands/host/claude

global_files: []

post_install_actions:
  - |
    cat <<'BANNER'

    ──────────────────────────────────────────────────────────────────
     ddev-claude installed.

     Default sidecar is minimum-viable: Claude Code + firewall only.
     To enable extras (currently: php), edit .ddev/claude.yaml:

         extras:
           - php

         extra_allowed_domains:
           - sentry.io

     Next steps:
       1. (optional) edit .ddev/claude.yaml
       2. export ANTHROPIC_API_KEY=sk-ant-...   (or OAuth on first run)
       3. ddev restart                           (~1-2 min first build)
       4. ddev claude                            (interactive YOLO mode)
                ddev claude safe                 (no --dangerously-skip-permissions)
                ddev claude shell                (bash in the sidecar)
                ddev claude exec <cmd>           (one-shot command)
                ddev claude rebuild              (after editing claude.yaml)

     State (auth, settings) lives at .ddev/.claude/ — gitignored.

     To uninstall:
       ddev add-on remove claude
    ──────────────────────────────────────────────────────────────────
    BANNER

removal_actions:
  - |
    # Remove addon-managed files only. User-managed files
    # (.ddev/claude.yaml, .ddev/.claude/, .ddev/claude.local/) are kept.
    set -e
    rm -f .ddev/claude/Dockerfile
    rm -f .ddev/claude/extra-domains.list
    rm -f .ddev/claude/.build-stamp
    echo "ddev-claude removed."
    echo "Preserved (user-managed; remove manually if desired):"
    echo "    .ddev/claude.yaml          (per-project config)"
    echo "    .ddev/.claude/             (auth/settings state)"
    echo "    .ddev/claude.local/        (escape-hatch fragments)"

yaml_read_files: {}
```

- [ ] **Step 9.2: Commit**

Run:
```
git add install.yaml
git commit -m "feat: install.yaml — state bootstrap, gitignore, removal

pre_install_actions creates .ddev/.claude/, chowns it to 1000:1000
best-effort, and appends /.claude/ + /claude.local/ + generated files
to .ddev/.gitignore. project_files now lists Dockerfile.base (not the
old Dockerfile), build-image.sh, config.claude.yaml, and the php
extra. removal_actions wipes only the generated files and leaves user
data alone."
```

---

## Task 10: Rewrite `tests/test.bats` (integration tests)

**Files:**
- Modify: `tests/test.bats`

Reorganize into the four groups from the spec. Many groups share `ddev start` setup, so we aggregate related assertions into single `@test` blocks to keep CI runtime manageable.

- [ ] **Step 10.1: Replace `tests/test.bats` with the new test suite**

Write `tests/test.bats`:
```bash
#!/usr/bin/env bats

# Integration tests for ddev-claude.
# These tests do a full ddev install + start, so each @test is slow (~1-2 min).
# For fast unit tests of build-image.sh, see tests/build-image.bats.
#
# Run locally:
#   bats tests/test.bats
#
# Requires: ddev (>= 1.24), docker, bats-core.

setup() {
  export DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )/.."
  export PROJNAME="claude-test"
  export TESTDIR="$(mktemp -d)"
  export DDEV_NONINTERACTIVE=true

  cd "$TESTDIR"
  ddev config --project-name="$PROJNAME" --project-type=php --docroot=. >/dev/null
  ddev start -y >/dev/null
}

teardown() {
  cd "$TESTDIR" || true
  ddev delete -Oy "$PROJNAME" >/dev/null 2>&1 || true
  rm -rf "$TESTDIR"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
install_addon() {
  ddev add-on get "$DIR" >/dev/null
}
in_sidecar() {
  ddev exec -s claude "$@"
}

# ===========================================================================
# Install + basic health
# ===========================================================================
@test "install: addon installs and sidecar comes up" {
  install_addon
  ddev restart >/dev/null

  # Compose fragment
  [ -f "$TESTDIR/.ddev/docker-compose.claude.yaml" ]
  # Pre-start hook config
  [ -f "$TESTDIR/.ddev/config.claude.yaml" ]
  # Generated Dockerfile (from build-image.sh on pre-start)
  [ -f "$TESTDIR/.ddev/claude/Dockerfile" ]
  # State dir bootstrapped
  [ -d "$TESTDIR/.ddev/.claude" ]
  # gitignore extended
  grep -qxF '/.claude/' "$TESTDIR/.ddev/.gitignore"
  grep -qxF '/claude.local/' "$TESTDIR/.ddev/.gitignore"
  # Host command installed
  [ -x "$TESTDIR/.ddev/commands/host/claude" ]
  # Sidecar container running
  docker ps --format '{{.Names}}' | grep -qx "ddev-${PROJNAME}-claude"
}

# ===========================================================================
# Group A — Isolation invariants (security)
# ===========================================================================
@test "isolation: default sidecar passes all 6 invariants" {
  install_addon
  ddev restart >/dev/null
  # Activate firewall (normally done by `ddev claude`; we trigger it directly).
  docker exec "ddev-${PROJNAME}-claude" sudo /usr/local/bin/init-firewall.sh >/dev/null 2>&1

  # 1. iptables OUTPUT policy is DROP
  run docker exec "ddev-${PROJNAME}-claude" sudo iptables -L OUTPUT -n
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "policy DROP" ]]

  # 2. example.com is blocked
  run docker exec --user claude "ddev-${PROJNAME}-claude" curl --max-time 3 -s -o /dev/null -w '%{http_code}' https://example.com
  # curl exit non-zero OR http_code is 000 — either is a block.
  [ "$status" -ne 0 ] || [ "$output" = "000" ]

  # 3. api.github.com is reachable
  run docker exec --user claude "ddev-${PROJNAME}-claude" curl --max-time 5 -s -o /dev/null -w '%{http_code}' https://api.github.com
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[23] ]]

  # 4. agent runs as uid 1000
  run docker exec --user claude "ddev-${PROJNAME}-claude" id -u
  [ "$status" -eq 0 ]
  [ "$output" = "1000" ]

  # 5. host home paths leak nowhere
  run docker exec --user claude "ddev-${PROJNAME}-claude" sh -c 'ls /Users 2>/dev/null; ls /home/'"$USER"' 2>/dev/null'
  [ -z "$output" ]

  # 6. sudo apt-get is rejected
  run docker exec --user claude "ddev-${PROJNAME}-claude" sudo -n apt-get install -y htop
  [ "$status" -ne 0 ]
}

# ===========================================================================
# Group B — Build pipeline
# ===========================================================================
@test "build: no extras → minimal image (no php, no gh)" {
  install_addon
  ddev restart >/dev/null

  run docker exec "ddev-${PROJNAME}-claude" sh -c 'command -v php'
  [ "$status" -ne 0 ]
  run docker exec "ddev-${PROJNAME}-claude" sh -c 'command -v composer'
  [ "$status" -ne 0 ]
  run docker exec "ddev-${PROJNAME}-claude" sh -c 'command -v gh'
  [ "$status" -ne 0 ]
}

@test "build: extras: [php] → php + composer present; packagist allowed" {
  install_addon
  cat > "$TESTDIR/.ddev/claude.yaml" <<'YAML'
extras:
  - php
YAML
  ddev restart >/dev/null

  # php and composer installed
  run docker exec "ddev-${PROJNAME}-claude" php -v
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PHP 8.5" ]]
  run docker exec "ddev-${PROJNAME}-claude" composer --version
  [ "$status" -eq 0 ]

  # Firewall reachability: packagist
  docker exec "ddev-${PROJNAME}-claude" sudo /usr/local/bin/init-firewall.sh >/dev/null 2>&1
  run docker exec --user claude "ddev-${PROJNAME}-claude" curl --max-time 5 -s -o /dev/null -w '%{http_code}' https://repo.packagist.org/packages.json
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[23] ]]
}

@test "build: escape hatch — claude.local/Dockerfile.fragment is applied" {
  install_addon
  mkdir -p "$TESTDIR/.ddev/claude.local"
  cat > "$TESTDIR/.ddev/claude.local/Dockerfile.fragment" <<'F'
USER root
RUN echo escape-hatch-marker > /opt/escape-hatch-marker
F
  ddev restart >/dev/null

  run docker exec "ddev-${PROJNAME}-claude" cat /opt/escape-hatch-marker
  [ "$status" -eq 0 ]
  [[ "$output" =~ escape-hatch-marker ]]
}

# ===========================================================================
# Group C — State + config lifecycle
# ===========================================================================
@test "state: addon removal preserves user files" {
  install_addon
  cat > "$TESTDIR/.ddev/claude.yaml" <<'YAML'
extras: []
YAML
  mkdir -p "$TESTDIR/.ddev/claude.local"
  echo "marker" > "$TESTDIR/.ddev/claude.local/userfile.txt"
  ddev restart >/dev/null

  run ddev add-on remove claude
  [ "$status" -eq 0 ]

  # Addon-managed files are gone
  [ ! -f "$TESTDIR/.ddev/docker-compose.claude.yaml" ]
  [ ! -f "$TESTDIR/.ddev/config.claude.yaml" ]
  [ ! -f "$TESTDIR/.ddev/commands/host/claude" ]
  [ ! -f "$TESTDIR/.ddev/claude/Dockerfile" ]
  [ ! -f "$TESTDIR/.ddev/claude/Dockerfile.base" ]
  [ ! -f "$TESTDIR/.ddev/claude/build-image.sh" ]

  # User-managed files are preserved
  [ -f "$TESTDIR/.ddev/claude.yaml" ]
  [ -d "$TESTDIR/.ddev/.claude" ]
  [ -f "$TESTDIR/.ddev/claude.local/userfile.txt" ]
}

# ===========================================================================
# Group D — CLI
# ===========================================================================
@test "cli: ddev claude help lists subcommands" {
  install_addon
  ddev restart >/dev/null

  run ddev claude help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ddev claude safe" ]]
  [[ "$output" =~ "ddev claude shell" ]]
  [[ "$output" =~ "ddev claude exec" ]]
  [[ "$output" =~ "ddev claude rebuild" ]]
}

@test "cli: ddev claude exec runs in sidecar as uid 1000" {
  install_addon
  ddev restart >/dev/null

  run ddev claude exec id -u
  [ "$status" -eq 0 ]
  [ "$output" = "1000" ]
}

@test "cli: ddev claude exec propagates exit codes" {
  install_addon
  ddev restart >/dev/null

  run ddev claude exec false
  [ "$status" -ne 0 ]
}

@test "cli: ddev claude rebuild regenerates Dockerfile" {
  install_addon
  ddev restart >/dev/null

  # Capture stamp before
  stamp1="$(cat "$TESTDIR/.ddev/claude/.build-stamp")"

  # Change extras
  cat > "$TESTDIR/.ddev/claude.yaml" <<'YAML'
extras:
  - php
YAML
  run ddev claude rebuild
  [ "$status" -eq 0 ]

  stamp2="$(cat "$TESTDIR/.ddev/claude/.build-stamp")"
  [ "$stamp1" != "$stamp2" ]

  # Dockerfile now mentions packages.sury.org (php fragment marker)
  grep -qF 'packages.sury.org' "$TESTDIR/.ddev/claude/Dockerfile"
}
```

**Note on spec test #20 (CLAUDE_SAFE → absence of `--dangerously-skip-permissions`):** Verifying which argv `claude` received from inside `docker exec` would require a `CLAUDE_BIN_OVERRIDE` stub mechanism. That instrumentation is more invasive than the assertion is worth — the `safe` branch in the subcommand router is a single short case (`safe) ... CLAUDE_SAFE=1 launch_claude "$@" ;;`) and `launch_claude`'s flag-toggle is one line, both verifiable by inspection. If a regression appears later, the cheapest add is a stub `claude` binary inside the sidecar via `ddev claude exec sh -c 'ln -sf /usr/bin/env $HOME/.local/bin/claude'` plus an argv-logging wrapper script — but that's a follow-up, not MVP.

- [ ] **Step 10.2: Validate bats syntax**

Run:
```
bats --no-tempdir-cleanup --pretty tests/test.bats --filter 'install: addon installs and sidecar comes up' --tap 2>&1 | head -20
```
Expected: bats parses the file and runs the first test (it may pass or fail at runtime depending on whether docker/ddev are reachable in your environment — we only need to confirm bats can parse and execute). If you see a parse error from bats itself ("syntax error near unexpected token"), fix it.

If you can't easily run ddev locally, at minimum confirm syntactic validity:
```
bash -n tests/test.bats
```
Expected: no output, exit 0.

- [ ] **Step 10.3: Commit**

Run:
```
git add tests/test.bats
git commit -m "test: rewrite integration tests for the new architecture

Covers the four groups from the spec: install/health, isolation
invariants (6 checks aggregated into one @test for CI cost), build
pipeline (no-extras / php / escape-hatch), state lifecycle (addon
removal preserves user files), and CLI subcommands (help, exec,
rebuild, exit-code propagation)."
```

---

## Task 11: Update `README.md`

**Files:**
- Modify: `README.md`

The README needs material rewrites: the "What you get" section is stale, install instructions need a `.ddev/claude.yaml` note, the commands section needs the new subcommands, the architecture diagram references should mention `claude.yaml`, and we add a "Cookbook" section for the escape hatch.

- [ ] **Step 11.1: Replace `README.md` with the updated version**

Write `README.md`:
````markdown
# ddev-claude

A [DDEV](https://ddev.com) add-on that adds a **sandboxed sidecar
container** for running [Claude Code](https://docs.claude.com/en/docs/claude-code/overview)
(Anthropic's AI coding CLI) with `--dangerously-skip-permissions` (YOLO
mode) safely contained behind an iptables + ipset + dnsmasq firewall.

The default sidecar is **minimum viable**: Claude Code + firewall, on
`debian:bookworm-slim`. Anything project-specific (PHP, gh, etc.) is
added through a small opt-in extras catalog.

## What you get (default)

- A `claude` sidecar built from `debian:bookworm-slim` with:
  - Claude Code CLI (native binary, installed via Anthropic's official
    installer — no Node.js dependency)
  - git, bash, sudo, curl, ca-certificates
  - iptables/ipset/dnsmasq/dnsutils/iproute2 for the firewall
- An **outbound firewall** (default-DROP policy) that only allows:
  - `github.com`, `api.github.com`
  - `anthropic.com`, `claude.ai`
  - The DDEV internal network (so the agent can reach `web`, `db`, …)
- A `ddev claude` host command with subcommands (`safe`, `shell`,
  `exec`, `rebuild`, `help`).
- Persistent Claude Code auth + settings at `.ddev/.claude/` (gitignored).

## Adding extras

To add tooling your project needs, edit `.ddev/claude.yaml`:

```yaml
# Available extras: php
extras:
  - php

# Additional outbound domains the runtime firewall should allow.
extra_allowed_domains:
  - sentry.io
  - api.stripe.com
```

Run `ddev claude rebuild` (or `ddev restart`) to regenerate the
Dockerfile. The new image is built on the next `ddev start`.

**Currently shipped extras:** `php` (PHP 8.5 CLI + Composer + common
extensions; adds `packagist.org` + `repo.packagist.org` to the
runtime allow-list).

For anything not in the catalog, use the escape hatch (see **Cookbook**
below).

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

# Optional: GitHub auth (for git push, gh CLI when added as an extra)
export GITHUB_PERSONAL_ACCESS_TOKEN=ghp_...

# (optional) edit .ddev/claude.yaml to opt into extras
# Then start / restart the DDEV stack
ddev restart

# Launch Claude Code in YOLO mode inside the sandbox
ddev claude

# Subcommands
ddev claude safe              # without --dangerously-skip-permissions
ddev claude shell             # bash inside the sidecar (firewall active)
ddev claude exec composer install   # run a single command (one-shot)
ddev claude rebuild           # regenerate Dockerfile after editing claude.yaml
ddev claude help              # show this list

# Pass-through to the claude CLI
ddev claude --resume
ddev claude -p "summarize this repo"
```

`CLAUDE_SAFE=1 ddev claude` is still honored for back-compat.

## Cookbook (escape hatch)

For tooling not in the catalog, drop fragments into `.ddev/claude.local/`:

### Add the GitHub CLI

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

(No `.ddev/claude.local/extra-domains.list` entry needed — `github.com` is in
the default allow-list.)

### Add Node.js + npm (for npm-based MCPs)

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

### Add Playwright + Chromium

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

(Requires the Node.js fragment above to be present first.)

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
│   .ddev/claude.yaml ──► build-image.sh ──► .ddev/claude/Dockerfile   │
│                          (pre-start hook)                             │
│                                                                      │
│   ddev claude ──► docker exec ──► ┌─ claude sidecar ──────────────┐  │
│                                   │  Claude Code CLI (native)     │  │
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

## How the firewall works

`init-firewall.sh` (run as root via a NOPASSWD sudoers entry) sets up:

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
6. **Smoke tests** — `curl` reachability checks for github (must
   succeed) and `example.com` (must fail).

## Known limitations

- **No IPv6**: dropped entirely. Extend `init-firewall.sh` to
  dual-stack the allow-list if needed.
- **DNS open on port 53**: required for dnsmasq upstreams; a determined
  agent could in theory use DNS tunneling for exfiltration.
- **`.git` and `.env*` are bind-mounted**: the agent can read (and
  potentially commit) anything in your project directory. Keep secrets
  out of the working tree, or use `CLAUDE_SAFE=1` for untrusted tasks.
- **UID 1000 hardcoded**: the `claude` user inside the container is
  uid 1000. If your host user uses a different uid, file ownership may
  look strange on `.ddev/.claude/`. Adjust via Dockerfile build args if needed.
- **`.ddev/.claude/` holds auth state**: a determined agent could plant
  configuration there (e.g., a malicious MCP entry in
  `~/.claude/settings.json`) that runs in the next session. Such code
  still runs under the same firewall + uid, so it cannot break out, but
  the persistence vector is real.

## Uninstall

```bash
ddev add-on remove claude
ddev restart
```

Addon-managed files are removed. Preserved (delete manually if
desired):

```bash
rm -rf .ddev/claude.yaml .ddev/.claude/ .ddev/claude.local/
```

## License

MIT — see [LICENSE](LICENSE).
````

- [ ] **Step 11.2: Commit**

Run:
```
git add README.md
git commit -m "docs: rewrite README for minimum-viable architecture

Updates 'what you get' to the lean default, documents
.ddev/claude.yaml, adds a Cookbook section showing gh / node /
Playwright via the .ddev/claude.local/ escape hatch, replaces the
two-named-volume note with .ddev/.claude/, and refreshes the
architecture diagram."
```

---

## Task 12: End-to-end CI smoke run

**Files:** none changed.

- [ ] **Step 12.1: Run the fast unit tests**

Run:
```
bats tests/build-image.bats
```
Expected: `12 tests, 0 failures`. If anything is red, fix before continuing.

- [ ] **Step 12.2: Run a single integration test locally to confirm install works**

Run:
```
bats tests/test.bats --filter 'install: addon installs and sidecar comes up'
```
Expected: passes. If it fails, the message will say which artifact is missing — fix and re-run.

- [ ] **Step 12.3: Run the full integration suite**

Run:
```
bats tests/test.bats
```
Expected: all tests pass. If a test fails on a particular assertion, fix the underlying file (e.g., a typo in init-firewall.sh) and re-run. **Do not skip failing tests.**

- [ ] **Step 12.4: Verify CI workflow is still valid**

Run:
```
cat .github/workflows/tests.yml
```
Expected: existing `bats tests/test.bats` invocation. To also run the unit tests in CI, the workflow needs one tweak — change the "Run tests" step to:

```yaml
      - name: Run tests
        run: |
          bats tests/build-image.bats
          bats tests/test.bats
```

Apply this edit if not already done:

Edit `.github/workflows/tests.yml`, replace:
```yaml
      - name: Run tests
        run: bats tests/test.bats
```
with:
```yaml
      - name: Run tests
        run: |
          bats tests/build-image.bats
          bats tests/test.bats
```

- [ ] **Step 12.5: Commit the workflow tweak (if changed)**

Run:
```
git diff --quiet .github/workflows/tests.yml || (git add .github/workflows/tests.yml && git commit -m "ci: run build-image unit tests alongside integration tests")
```

- [ ] **Step 12.6: Push and verify CI**

Run:
```
git push
```
Expected: GitHub Actions runs `tests` workflow on the push. Watch it via `gh run watch` (or the Actions UI). Confirm both bats files run green.

---

## Definition of done

- All commits land on `main`.
- `bats tests/build-image.bats` is green locally and in CI.
- `bats tests/test.bats` is green locally and in CI.
- `ddev claude help` on a clean install lists `safe / shell / exec / rebuild / help`.
- `ddev claude rebuild` with `extras: [php]` produces a Dockerfile containing the sury apt-source line.
- `ddev claude` opens an interactive Claude Code session in YOLO mode against the firewalled sandbox.
- README's "Cookbook" section's `gh` example builds and runs without modification.
- `ddev add-on remove claude` leaves `.ddev/claude.yaml`, `.ddev/.claude/`, and `.ddev/claude.local/` intact.
