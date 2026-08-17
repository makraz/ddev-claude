#!/usr/bin/env bash
#ddev-generated
# ---------------------------------------------------------------------------
# entrypoint.sh — ddev-claude sidecar entrypoint.
#
# Runs as root (see `user: root` in docker-compose.claude.yaml) so it can
# activate the outbound firewall at container start. This makes the sandbox
# enforced for EVERY path into the container — `ddev claude`, `ddev claude
# shell`, plain `ddev exec -s claude`, and direct `docker exec` — not just the
# `ddev claude` host command.
#
# After activation it idles as PID 1 (`sleep infinity`) so the container stays
# up; interactive Claude Code sessions are launched on demand, as uid 1000,
# by the `ddev claude` host command.
# ---------------------------------------------------------------------------
set -uo pipefail

# Overridable for the bats suite; these are the real paths inside the image.
STATE_DIR="${STATE_DIR:-/home/claude/.claude}"
SEED_SRC="${SEED_SRC:-/mnt/ddev_config/.claude}"
SANDBOX_SETTINGS="${SANDBOX_SETTINGS:-/etc/claude-sandbox/settings.json}"
RUNTIME_LIST="${RUNTIME_LIST:-/etc/claude-firewall/runtime-domains.list}"

# One-shot, non-destructive migration of the pre-v0.4.0 host state directory
# into the state volume. The sentinel is written ONLY after a complete copy, so
# a container killed mid-seed retries into a clean state on the next start.
seed_state_dir() {
  mkdir -p "$STATE_DIR"
  local sentinel="$STATE_DIR/.ddev-claude-seeded"

  if [[ -f "$sentinel" ]]; then
    return 0
  fi

  if [[ -d "$SEED_SRC" ]]; then
    echo "[entrypoint] seeding state volume from $SEED_SRC"
    if ! cp -a "$SEED_SRC/." "$STATE_DIR/"; then
      echo "[entrypoint] WARNING: state seed failed; will retry on next start" >&2
      return 0
    fi
  fi

  [[ -n "${SKIP_CHOWN:-}" ]] || chown -R 1000:1000 "$STATE_DIR"
  : > "$sentinel"
  [[ -n "${SKIP_CHOWN:-}" ]] || chown 1000:1000 "$sentinel"
}

# Re-assert the generated settings on EVERY start, so a plugin the agent
# enables mid-session does not survive a restart.
install_sandbox_settings() {
  [[ -r "$SANDBOX_SETTINGS" ]] || return 0
  cp "$SANDBOX_SETTINGS" "$STATE_DIR/settings.json" || {
    echo "[entrypoint] WARNING: could not install sandbox settings" >&2
    return 0
  }
  [[ -n "${SKIP_CHOWN:-}" ]] || chown 1000:1000 "$STATE_DIR/settings.json"
}

persist_runtime_domains() {
  mkdir -p "$(dirname "$RUNTIME_LIST")"
  : > "$RUNTIME_LIST"
  chmod 0644 "$RUNTIME_LIST"
  if [[ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]]; then
    # shellcheck disable=SC2086
    for d in ${EXTRA_ALLOWED_DOMAINS}; do
      printf '%s\n' "$d" >> "$RUNTIME_LIST"
    done
  fi
}

main() {
  if [[ "$(id -u)" -eq 0 ]]; then
    seed_state_dir
    install_sandbox_settings
    persist_runtime_domains

    if /usr/local/bin/init-firewall.sh; then
      echo "[entrypoint] firewall active"
    else
      # Non-fatal: keep the container up so the user can inspect it. The
      # firewall is re-asserted (idempotently) by the `ddev claude` host
      # command, so a transient start-time failure self-heals.
      echo "[entrypoint] WARNING: firewall init failed; will retry on 'ddev claude'" >&2
    fi
  else
    echo "[entrypoint] WARNING: not running as root; cannot activate firewall" >&2
  fi

  exec sleep infinity
}

# `--source-only` lets the bats suite load the functions without running them.
if [[ "${1:-}" != "--source-only" ]]; then
  main "$@"
fi
