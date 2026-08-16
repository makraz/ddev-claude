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

# Portable mtime-in-epoch-seconds. GNU stat first (Linux/CI): `stat -f` there means
# --file-system and would dump a verbose, run-varying block instead of the mtime, so
# BSD `stat -f %m` must only be the fallback (macOS).
mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
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
  mtime1="$(mtime "$PROJ/.ddev/claude/Dockerfile")"
  sleep 1
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  mtime2="$(mtime "$PROJ/.ddev/claude/Dockerfile")"
  [ "$mtime1" = "$mtime2" ]
}

@test "build stamp: changed config → regenerates" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extras:
  - php
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  mtime1="$(mtime "$PROJ/.ddev/claude/Dockerfile")"
  sleep 1
  # remove php from extras
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extras: []
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  mtime2="$(mtime "$PROJ/.ddev/claude/Dockerfile")"
  [ "$mtime2" -gt "$mtime1" ]
}

@test "parser: mount_mode scalar is accepted" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
mount_mode: bind
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
}

@test "parser: invalid mount_mode → exits non-zero with clear error" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
mount_mode: turbo
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid mount_mode 'turbo'" ]]
}

@test "parser: list key given a scalar value → clear error" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extras: php
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "expects a block list" ]]
}

@test "parser: 'extras: []' empty-list shorthand still works" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
extras: []
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
}

@test "parser: tools and plugins lists are accepted" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
tools:
  - Read
  - Bash
plugins:
  - superpowers
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
}

@test "parser: unrecognised tool name warns but exits 0" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
tools:
  - Read
  - Telepathy
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "unrecognised tool 'Telepathy'" ]]
}

@test "parser: malformed plugin name → exits non-zero" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
plugins:
  - "bad name!"
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "invalid plugin" ]]
}

@test "parser: unknown top-level scalar key → clear error" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
nonsense: 1
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown key 'nonsense'" ]]
}

@test "generator: absent tools key → default four tools in tools.list" {
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  run cat "$PROJ/.ddev/claude/tools.list"
  [ "$output" = "Read
Write
Bash
Skill" ]
}

@test "generator: explicit tools key overrides the default" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
tools:
  - Read
  - Bash
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  run cat "$PROJ/.ddev/claude/tools.list"
  [ "$output" = "Read
Bash" ]
}

@test "generator: absent plugins key → default four in settings.json" {
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  run grep -c '@claude-plugins-official": true' "$PROJ/.ddev/claude/settings.json"
  [ "$output" -eq 4 ]
}

@test "generator: bare plugin name gains the default marketplace" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
plugins:
  - superpowers
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  run grep -F '"superpowers@claude-plugins-official": true' "$PROJ/.ddev/claude/settings.json"
  [ "$status" -eq 0 ]
}

@test "generator: explicit marketplace is preserved" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
plugins:
  - mything@my-marketplace
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  run grep -F '"mything@my-marketplace": true' "$PROJ/.ddev/claude/settings.json"
  [ "$status" -eq 0 ]
}

@test "generator: changing tools changes the build stamp" {
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  local first
  first="$(cat "$PROJ/.ddev/claude/.build-stamp")"
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
tools:
  - Read
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.ddev/claude/.build-stamp")" != "$first" ]
}

@test "generator: changing plugins changes the build stamp" {
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  local first
  first="$(cat "$PROJ/.ddev/claude/.build-stamp")"
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
plugins:
  - code-review
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.ddev/claude/.build-stamp")" != "$first" ]
}

@test "mount: mount_mode bind → bind override, no mutagen volume" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
mount_mode: bind
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  run grep -F '../:/var/www/html' "$PROJ/.ddev/docker-compose.claude-mounts.yaml"
  [ "$status" -eq 0 ]
  run grep -F 'project_mutagen' "$PROJ/.ddev/docker-compose.claude-mounts.yaml"
  [ "$status" -ne 0 ]
  [ "$(cat "$PROJ/.ddev/claude/.mount-mode")" = "bind" ]
}

@test "mount: mount_mode mutagen → volume override, no root bind" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
mount_mode: mutagen
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  run grep -F 'source: project_mutagen' "$PROJ/.ddev/docker-compose.claude-mounts.yaml"
  [ "$status" -eq 0 ]
  run grep -Fx '            - ../:/var/www/html' "$PROJ/.ddev/docker-compose.claude-mounts.yaml"
  [ "$status" -ne 0 ]
  [ "$(cat "$PROJ/.ddev/claude/.mount-mode")" = "mutagen" ]
}

@test "mount: both overrides always declare the claude_state volume" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
mount_mode: bind
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  run grep -F 'claude_state' "$PROJ/.ddev/docker-compose.claude-mounts.yaml"
  [ "$status" -eq 0 ]
}

# Regression guard. The pre-v0.4.0 docker-compose.claude.yaml mounted
# ../.ddev/.claude/bash_history.d at /home/claude/.bash_history.d. Task 3
# replaced the whole volumes: block and the first draft dropped this mount
# entirely — silently losing shell-history persistence across restarts. The
# base image sets that path and image/Dockerfile is frozen this release, so
# the mount has to come from the generated override.
@test "mount: both variants mount the bash history dir" {
  for mode in bind mutagen; do
    printf 'mount_mode: %s\n' "$mode" > "$PROJ/.ddev/claude.yaml"
    run "$PROJ/.ddev/claude/build-image.sh"
    [ "$status" -eq 0 ]
    run grep -Fx '            - ../.ddev/.claude/bash_history.d:/home/claude/.bash_history.d' \
      "$PROJ/.ddev/docker-compose.claude-mounts.yaml"
    [ "$status" -eq 0 ]
  done
}

@test "mount: auto reads performance_mode from project config.yaml" {
  printf 'name: demo\nperformance_mode: mutagen\n' > "$PROJ/.ddev/config.yaml"
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
mount_mode: auto
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.ddev/claude/.mount-mode")" = "mutagen" ]
}

@test "mount: auto honours performance_mode none in project config.yaml" {
  printf 'name: demo\nperformance_mode: none\n' > "$PROJ/.ddev/config.yaml"
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.ddev/claude/.mount-mode")" = "bind" ]
}

@test "mount: auto ignores a commented-out performance_mode" {
  printf 'name: demo\n# performance_mode: mutagen\n' > "$PROJ/.ddev/config.yaml"
  export DDEV_GLOBAL_DIR="$PROJ/fake-global"
  mkdir -p "$DDEV_GLOBAL_DIR"
  printf 'performance_mode: none\n' > "$DDEV_GLOBAL_DIR/global_config.yaml"
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$PROJ/.ddev/claude/.mount-mode")" = "bind" ]
}

@test "mount: changing the resolved mount mode changes the build stamp" {
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
mount_mode: bind
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  local first
  first="$(cat "$PROJ/.ddev/claude/.build-stamp")"
  cat > "$PROJ/.ddev/claude.yaml" <<'YAML'
mount_mode: mutagen
YAML
  run "$PROJ/.ddev/claude/build-image.sh"
  [ "$(cat "$PROJ/.ddev/claude/.build-stamp")" != "$first" ]
}
