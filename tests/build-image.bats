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
