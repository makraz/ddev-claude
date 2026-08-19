#!/usr/bin/env bats

# Unit tests for the state-seeding half of claude/entrypoint.sh.
# The seeding logic is sourced as a function so it can run without root,
# iptables, or a container.

setup() {
  export REPO="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )/.."
  export T="$(mktemp -d)"
  export STATE_DIR="$T/state"
  export SEED_SRC="$T/seed"
  export SKIP_CHOWN=1
  mkdir -p "$STATE_DIR" "$SEED_SRC"
}

teardown() {
  rm -rf "$T"
}

run_seed() {
  # shellcheck disable=SC1090
  source "$REPO/claude/entrypoint.sh" --source-only
  seed_state_dir
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

@test "entrypoint: does NOT overwrite the user's own settings.json" {
  # Regression guard. An earlier version copied the generated file (which
  # contains ONLY enabledPlugins) over the user's settings.json on every start,
  # silently destroying their model / hooks / statusline / env preferences.
  # The curated plugin set is now layered on by the shim via `--settings`
  # instead, so the entrypoint must leave this file completely alone.
  : > "$STATE_DIR/.ddev-claude-seeded"
  printf '{"model":"opus","statusLine":{"type":"command"}}\n' > "$STATE_DIR/settings.json"
  run run_seed
  [ "$status" -eq 0 ]
  run cat "$STATE_DIR/settings.json"
  [[ "$output" =~ '"model":"opus"' ]]
  [[ "$output" =~ statusLine ]]
}

# ---------------------------------------------------------------------------
# remap_user_to_host
#
# There is no real `claude` system user (or root) on the test host, so `id`,
# `getent`, `usermod`, `groupmod`, `chown` are stubbed via a PATH directory
# that shadows the real binaries and logs every invocation to $CALL_LOG. This
# exercises the function's decision logic (no-op conditions, collision
# detection, which commands run with which arguments) without requiring an
# actual root/container environment.
# ---------------------------------------------------------------------------
setup_remap_stubs() {
  export STUB_BIN="$T/stubbin"
  export CALL_LOG="$T/calls.log"
  mkdir -p "$STUB_BIN"
  : > "$CALL_LOG"

  cat > "$STUB_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-u" && "$2" == "claude" ]]; then
  echo "${FAKE_CURRENT_UID:-1000}"
  exit 0
fi
if [[ "$1" == "-g" && "$2" == "claude" ]]; then
  echo "${FAKE_CURRENT_GID:-1000}"
  exit 0
fi
echo "0"
EOF

  cat > "$STUB_BIN/getent" <<'EOF'
#!/usr/bin/env bash
db="$1"; key="$2"
if [[ "$db" == "passwd" && -n "${FAKE_UID_COLLISION_ID:-}" && "$key" == "$FAKE_UID_COLLISION_ID" ]]; then
  echo "${FAKE_UID_COLLISION_NAME}:x:$key:$key::/home/x:/bin/bash"
  exit 0
fi
if [[ "$db" == "group" && -n "${FAKE_GID_COLLISION_ID:-}" && "$key" == "$FAKE_GID_COLLISION_ID" ]]; then
  echo "${FAKE_GID_COLLISION_NAME}:x:$key:"
  exit 0
fi
exit 2
EOF

  cat > "$STUB_BIN/usermod" <<'EOF'
#!/usr/bin/env bash
echo "usermod $*" >> "$CALL_LOG"
exit "${FAKE_USERMOD_EXIT:-0}"
EOF

  cat > "$STUB_BIN/groupmod" <<'EOF'
#!/usr/bin/env bash
echo "groupmod $*" >> "$CALL_LOG"
exit "${FAKE_GROUPMOD_EXIT:-0}"
EOF

  cat > "$STUB_BIN/chown" <<'EOF'
#!/usr/bin/env bash
echo "chown $*" >> "$CALL_LOG"
exit 0
EOF

  chmod +x "$STUB_BIN"/id "$STUB_BIN"/getent "$STUB_BIN"/usermod "$STUB_BIN"/groupmod "$STUB_BIN"/chown
  export PATH="$STUB_BIN:$PATH"
}

run_remap() {
  # shellcheck disable=SC1090
  source "$REPO/claude/entrypoint.sh" --source-only
  remap_user_to_host
}

@test "entrypoint: remap is a no-op when DDEV_UID is unset" {
  setup_remap_stubs
  unset DDEV_UID DDEV_GID
  run run_remap
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ]
}

@test "entrypoint: remap is a no-op when DDEV_UID equals the current uid" {
  setup_remap_stubs
  export FAKE_CURRENT_UID=1000
  export DDEV_UID=1000
  export DDEV_GID=1000
  run run_remap
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ]
}

@test "entrypoint: remap refuses to target uid 0" {
  setup_remap_stubs
  export FAKE_CURRENT_UID=1000
  export DDEV_UID=0
  export DDEV_GID=0
  run run_remap
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ]
}

@test "entrypoint: remap skips (does not touch /etc/passwd) when the target uid is already taken" {
  setup_remap_stubs
  export FAKE_CURRENT_UID=1000
  export DDEV_UID=501
  export DDEV_GID=20
  export FAKE_UID_COLLISION_ID=501
  export FAKE_UID_COLLISION_NAME=someoneelse
  run run_remap
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already used by 'someoneelse'" ]]
  run grep -c usermod "$CALL_LOG"
  [ "$output" -eq 0 ]
}

@test "entrypoint: remap skips only the gid when the target gid is already taken but still remaps the uid" {
  setup_remap_stubs
  export FAKE_CURRENT_UID=1000
  export DDEV_UID=501
  export DDEV_GID=20
  export FAKE_GID_COLLISION_ID=20
  export FAKE_GID_COLLISION_NAME=dialout
  run run_remap
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already used by 'dialout'" ]]
  run grep -c groupmod "$CALL_LOG"
  [ "$output" -eq 0 ]
  run grep "usermod -u 501 claude" "$CALL_LOG"
  [ "$status" -eq 0 ]
}

@test "entrypoint: remap changes uid and gid and chowns the home directory" {
  setup_remap_stubs
  export FAKE_CURRENT_UID=1000
  export DDEV_UID=501
  export DDEV_GID=20
  run run_remap
  [ "$status" -eq 0 ]
  run grep "groupmod -g 20 claude" "$CALL_LOG"
  [ "$status" -eq 0 ]
  run grep "usermod -u 501 -g 20 claude" "$CALL_LOG"
  [ "$status" -eq 0 ]
  run grep "chown -R claude:claude /home/claude" "$CALL_LOG"
  [ "$status" -eq 0 ]
}
