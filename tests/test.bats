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
  # gitignore extended (project root, not .ddev/.gitignore which DDEV regenerates)
  grep -qxF '/.ddev/.claude/' "$TESTDIR/.gitignore"
  grep -qxF '/.ddev/claude.local/' "$TESTDIR/.gitignore"
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

  # 3b. downloads.claude.ai is reachable (claude update). Any HTTP response
  # counts — a block shows up as curl failure / 000.
  run docker exec --user claude "ddev-${PROJNAME}-claude" curl --max-time 5 -s -o /dev/null -w '%{http_code}' https://downloads.claude.ai
  [ "$status" -eq 0 ]
  [ "$output" != "000" ]

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

@test "isolation: extra_allowed_domains in claude.yaml opens that domain" {
  install_addon
  cat > "$TESTDIR/.ddev/claude.yaml" <<'YAML'
extra_allowed_domains:
  - example.com
YAML
  ddev restart >/dev/null
  docker exec "ddev-${PROJNAME}-claude" sudo /usr/local/bin/init-firewall.sh >/dev/null 2>&1

  run docker exec --user claude "ddev-${PROJNAME}-claude" curl --max-time 5 -s -o /dev/null -w '%{http_code}' https://example.com
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[23] ]]
}

@test "isolation: EXTRA_ALLOWED_DOMAINS set before start opens that domain" {
  install_addon
  # The env var is consumed once, at container start, by entrypoint.sh (genuine
  # root, trusted compose env) — so it must be set BEFORE `ddev restart`.
  export EXTRA_ALLOWED_DOMAINS="example.com"
  ddev restart >/dev/null

  run docker exec --user claude "ddev-${PROJNAME}-claude" curl --max-time 5 -s -o /dev/null -w '%{http_code}' https://example.com
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[23] ]]
}

@test "isolation: firewall is active at container start (no ddev claude needed)" {
  install_addon
  ddev restart >/dev/null
  # Deliberately do NOT run init-firewall.sh by hand — entrypoint.sh should
  # have activated it at container start.

  run docker exec "ddev-${PROJNAME}-claude" sudo iptables -L OUTPUT -n
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ "policy DROP" ]]

  # A path that bypasses the `ddev claude` host command is still sandboxed.
  run docker exec --user claude "ddev-${PROJNAME}-claude" curl --max-time 3 -s -o /dev/null -w '%{http_code}' https://example.com
  [ "$status" -ne 0 ] || [ "$output" = "000" ]
}

@test "isolation: --ensure fast-paths when healthy but rebuilds when not" {
  install_addon
  ddev restart >/dev/null
  # entrypoint.sh ran a full init at start, so the ready marker exists.
  run docker exec "ddev-${PROJNAME}-claude" test -f /run/claude-firewall.ready
  [ "$status" -eq 0 ]

  # --ensure on a healthy firewall is a no-op fast path (and stays DROP).
  run docker exec "ddev-${PROJNAME}-claude" sudo /usr/local/bin/init-firewall.sh --ensure
  [ "$status" -eq 0 ]
  [[ "$output" =~ "skipping re-init" ]]
  run docker exec "ddev-${PROJNAME}-claude" sudo iptables -L OUTPUT -n
  [[ "${lines[0]}" =~ "policy DROP" ]]

  # If the marker is gone (transient start-time failure), --ensure does a full
  # rebuild and re-establishes the DROP policy + marker — self-heal preserved.
  docker exec "ddev-${PROJNAME}-claude" sudo rm -f /run/claude-firewall.ready
  run docker exec "ddev-${PROJNAME}-claude" sudo /usr/local/bin/init-firewall.sh --ensure
  [ "$status" -eq 0 ]
  [[ "$output" =~ "firewall ready" ]]
  run docker exec "ddev-${PROJNAME}-claude" test -f /run/claude-firewall.ready
  [ "$status" -eq 0 ]
}

@test "isolation: agent cannot tamper with the allow-list to widen egress" {
  install_addon
  ddev restart >/dev/null

  # The build-baked allow-list lives at a root-owned path the agent can't write.
  run docker exec --user claude "ddev-${PROJNAME}-claude" sh -c \
    'echo example.com >> /etc/claude-firewall/extra-domains.list'
  [ "$status" -ne 0 ]

  # Even exporting EXTRA_ALLOWED_DOMAINS in the agent's own shell and re-running
  # the firewall via sudo must NOT open the injected domain: the script ignores
  # its own environment and reads only root-owned allow-list files.
  docker exec --user claude "ddev-${PROJNAME}-claude" sh -c \
    'EXTRA_ALLOWED_DOMAINS=example.com sudo /usr/local/bin/init-firewall.sh' >/dev/null 2>&1 || true
  run docker exec --user claude "ddev-${PROJNAME}-claude" curl --max-time 3 -s -o /dev/null -w '%{http_code}' https://example.com
  [ "$status" -ne 0 ] || [ "$output" = "000" ]
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
