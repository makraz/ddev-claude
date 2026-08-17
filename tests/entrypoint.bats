#!/usr/bin/env bats

# Unit tests for the state-seeding half of claude/entrypoint.sh.
# The seeding logic is sourced as a function so it can run without root,
# iptables, or a container.

setup() {
  export REPO="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )/.."
  export T="$(mktemp -d)"
  export STATE_DIR="$T/state"
  export SEED_SRC="$T/seed"
  export SANDBOX_SETTINGS="$T/settings.json"
  export SKIP_CHOWN=1
  mkdir -p "$STATE_DIR" "$SEED_SRC"
  printf '{"enabledPlugins":{}}\n' > "$SANDBOX_SETTINGS"
}

teardown() {
  rm -rf "$T"
}

run_seed() {
  # shellcheck disable=SC1090
  source "$REPO/claude/entrypoint.sh" --source-only
  seed_state_dir
  install_sandbox_settings
}

@test "entrypoint: seeds an empty state dir from the host copy" {
  printf 'creds\n' > "$SEED_SRC/.credentials.json"
  run run_seed
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/.credentials.json" ]
  [ -f "$STATE_DIR/.ddev-claude-seeded" ]
}

@test "entrypoint: does not re-seed when the sentinel exists" {
  : > "$STATE_DIR/.ddev-claude-seeded"
  printf 'creds\n' > "$SEED_SRC/.credentials.json"
  run run_seed
  [ "$status" -eq 0 ]
  [ ! -f "$STATE_DIR/.credentials.json" ]
}

@test "entrypoint: writes the sentinel even when there is nothing to seed" {
  rm -rf "$SEED_SRC"
  run run_seed
  [ "$status" -eq 0 ]
  [ -f "$STATE_DIR/.ddev-claude-seeded" ]
}

@test "entrypoint: installs sandbox settings on every start" {
  printf '{"enabledPlugins":{"x@y":true}}\n' > "$SANDBOX_SETTINGS"
  : > "$STATE_DIR/.ddev-claude-seeded"
  printf '{"tampered":true}\n' > "$STATE_DIR/settings.json"
  run run_seed
  [ "$status" -eq 0 ]
  run cat "$STATE_DIR/settings.json"
  [[ "$output" =~ '"x@y":true' ]]
  [[ ! "$output" =~ tampered ]]
}
