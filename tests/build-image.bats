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
