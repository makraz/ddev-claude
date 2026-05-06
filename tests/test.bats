#!/usr/bin/env bats

# Bats tests for ddev-claude.
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

health_checks() {
  # Compose fragment in place
  [ -f "$TESTDIR/.ddev/docker-compose.claude.yaml" ]
  # Sidecar build context in place
  [ -f "$TESTDIR/.ddev/claude/Dockerfile" ]
  [ -x "$TESTDIR/.ddev/claude/init-firewall.sh" ]
  # Host command installed
  [ -x "$TESTDIR/.ddev/commands/host/claude" ]
  # Sidecar container running
  docker ps --format '{{.Names}}' | grep -qx "ddev-${PROJNAME}-claude"
}

@test "install from directory" {
  cd "$TESTDIR"
  run ddev add-on get "$DIR"
  [ "$status" -eq 0 ]
  ddev restart >/dev/null
  run health_checks
  [ "$status" -eq 0 ]
}

@test "install from release" {
  [ -n "${GITHUB_REPO_REF:-}" ] || skip "GITHUB_REPO_REF not set"
  cd "$TESTDIR"
  run ddev add-on get "$GITHUB_REPO_REF"
  [ "$status" -eq 0 ]
  ddev restart >/dev/null
  run health_checks
  [ "$status" -eq 0 ]
}
