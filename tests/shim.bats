#!/usr/bin/env bats

# Unit tests for claude/claude-shim, run against a stubbed "real" binary.

setup() {
  export REPO="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )/.."
  export SANDBOX="$(mktemp -d)"

  # Stub the real claude binary: echo its argv, one arg per line.
  mkdir -p "$SANDBOX/real"
  cat > "$SANDBOX/real/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@"
STUB
  chmod +x "$SANDBOX/real/claude"

  mkdir -p "$SANDBOX/etc"
  export TOOLS_FILE="$SANDBOX/etc/tools.list"
  export SETTINGS_FILE="$SANDBOX/etc/settings.json"

  # The shim reads NOTHING from the environment — an agent inside the container
  # could set such a variable and hand itself any tool set. Tests therefore
  # patch the two hardcoded paths into a throwaway copy instead.
  sed -e "s#^REAL=.*#REAL=$SANDBOX/real/claude#" \
      -e "s#^TOOLS_FILE=.*#TOOLS_FILE=$TOOLS_FILE#" \
      -e "s#^SETTINGS_FILE=.*#SETTINGS_FILE=$SETTINGS_FILE#" \
      "$REPO/claude/claude-shim" > "$SANDBOX/claude"
  chmod 0755 "$SANDBOX/claude"
}

teardown() {
  rm -rf "$SANDBOX"
}

@test "shim: injects --tools from tools.list" {
  printf 'Read\nWrite\nBash\nSkill\n' > "$TOOLS_FILE"
  run "$SANDBOX/claude"
  [ "$status" -eq 0 ]
  [ "$output" = "--tools
Read,Write,Bash,Skill" ]
}

@test "shim: passes other args through after the injected flag" {
  printf 'Read\nBash\n' > "$TOOLS_FILE"
  run "$SANDBOX/claude" --resume
  [ "$status" -eq 0 ]
  [ "$output" = "--tools
Read,Bash
--resume" ]
}

@test "shim: no tools.list → no injected flag" {
  run "$SANDBOX/claude" --resume
  [ "$status" -eq 0 ]
  [ "$output" = "--resume" ]
}

@test "shim: empty tools.list → no injected flag" {
  : > "$TOOLS_FILE"
  run "$SANDBOX/claude" --resume
  [ "$status" -eq 0 ]
  [ "$output" = "--resume" ]
}

@test "shim: refuses a user-supplied --tools" {
  printf 'Read\n' > "$TOOLS_FILE"
  run "$SANDBOX/claude" --tools default
  [ "$status" -eq 64 ]
  [[ "$output" =~ "--tools is fixed by the ddev-claude sandbox" ]]
}

@test "shim: refuses --tools=VALUE form too" {
  printf 'Read\n' > "$TOOLS_FILE"
  run "$SANDBOX/claude" --tools=default
  [ "$status" -eq 64 ]
  [[ "$output" =~ "--tools is fixed by the ddev-claude sandbox" ]]
}

@test "shim: ignores environment overrides of its own paths" {
  printf 'Read\n' > "$TOOLS_FILE"
  run env TOOLS_FILE=/nonexistent REAL=/bin/false "$SANDBOX/claude"
  [ "$status" -eq 0 ]
  [ "$output" = "--tools
Read" ]
}

# The curated plugin set is layered on per invocation via --settings rather than
# written into the agent's own ~/.claude/settings.json, which an earlier version
# overwrote on every container start, destroying the user's own preferences.
@test "shim: injects --settings when the sandbox settings file exists" {
  printf 'Read\n' > "$TOOLS_FILE"
  printf '{"enabledPlugins":{}}\n' > "$SETTINGS_FILE"
  run "$SANDBOX/claude"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "--settings" ]]
  [[ "$output" =~ "$SETTINGS_FILE" ]]
}

@test "shim: omits --settings when the sandbox settings file is absent" {
  printf 'Read\n' > "$TOOLS_FILE"
  run "$SANDBOX/claude"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "--settings" ]]
}
