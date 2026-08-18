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
# up; interactive Claude Code sessions are launched on demand, as the
# unprivileged `claude` user (remapped to the host's uid/gid — see
# remap_user_to_host below), by the `ddev claude` host command.
# ---------------------------------------------------------------------------
set -uo pipefail

# Overridable for the bats suite; these are the real paths inside the image.
STATE_DIR="${STATE_DIR:-/home/claude/.claude}"
SEED_SRC="${SEED_SRC:-/mnt/ddev_config/.claude}"
SANDBOX_SETTINGS="${SANDBOX_SETTINGS:-/etc/claude-sandbox/settings.json}"
RUNTIME_LIST="${RUNTIME_LIST:-/etc/claude-firewall/runtime-domains.list}"

# Remap the `claude` user/group to the host's uid/gid (DDEV_UID/DDEV_GID,
# forwarded from docker-compose.claude.yaml).
#
# Why: under Mutagen, DDEV populates the synced volume with real POSIX
# ownership/mode from the host — files at 0600, directories at 0700, owned by
# the HOST uid. Bind mounts masked this for years (Docker presents a
# bind-mounted file as owned by whichever uid accesses it), but a named
# volume enforces real permission checks, so an agent whose uid doesn't match
# the host's is locked out of read, write, AND traversal. DDEV's own `web`
# container gets equivalent behavior for free by baking uid/gid into its
# image at build time; this sidecar's base image is frozen for this release,
# so the same effect happens here, at runtime, while we are still genuinely
# root and before any agent process exists.
#
# The security invariant was always "the agent runs unprivileged, never
# root" — uid 1000 was incidental. Remapping to the host's uid preserves that
# invariant; it must never remap to uid/gid 0.
#
# The `claude` username itself never changes here, only its numeric uid/gid —
# this matters because the sudoers entry (/etc/sudoers.d/claude-firewall)
# reads `claude ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh`, keyed
# on the NAME "claude". sudo resolves that entry by looking up the invoking
# user's name, so preserving the name preserves exactly the one privilege the
# agent is meant to keep — nothing more, nothing less.
remap_user_to_host() {
  local target_uid="${DDEV_UID:-}"
  local target_gid="${DDEV_GID:-}"
  local current_uid
  current_uid="$(id -u claude 2>/dev/null)" || current_uid=""

  if [[ -z "$current_uid" ]]; then
    echo "[entrypoint] WARNING: could not determine current uid of 'claude'; skipping uid/gid remap" >&2
    return 0
  fi

  if [[ -z "$target_uid" || "$target_uid" == "0" || "$target_uid" == "$current_uid" ]]; then
    return 0
  fi

  if [[ "$target_gid" == "0" ]]; then
    echo "[entrypoint] WARNING: DDEV_GID=0 would remap to root's group; ignoring gid, uid-only remap" >&2
    target_gid=""
  fi

  local do_uid=1
  local do_gid=1
  local owner

  owner="$(getent passwd "$target_uid" 2>/dev/null | cut -d: -f1)"
  if [[ -n "$owner" && "$owner" != "claude" ]]; then
    echo "[entrypoint] WARNING: uid $target_uid is already used by '$owner'; skipping uid remap to avoid corrupting /etc/passwd" >&2
    do_uid=0
  fi

  if [[ -n "$target_gid" ]]; then
    owner="$(getent group "$target_gid" 2>/dev/null | cut -d: -f1)"
    if [[ -n "$owner" && "$owner" != "claude" ]]; then
      echo "[entrypoint] WARNING: gid $target_gid is already used by '$owner'; skipping gid remap to avoid corrupting /etc/group" >&2
      do_gid=0
    fi
  else
    do_gid=0
  fi

  if [[ "$do_uid" -eq 0 && "$do_gid" -eq 0 ]]; then
    return 0
  fi

  if [[ "$do_gid" -eq 1 ]]; then
    if ! groupmod -g "$target_gid" claude; then
      echo "[entrypoint] WARNING: groupmod to gid $target_gid failed; leaving group unchanged" >&2
      do_gid=0
    fi
  fi

  if [[ "$do_uid" -eq 1 ]]; then
    local usermod_args=(-u "$target_uid")
    [[ "$do_gid" -eq 1 ]] && usermod_args+=(-g "$target_gid")
    if ! usermod "${usermod_args[@]}" claude; then
      echo "[entrypoint] WARNING: usermod to uid $target_uid failed; uid unchanged" >&2
      do_uid=0
    fi
  fi

  if [[ "$do_uid" -eq 1 || "$do_gid" -eq 1 ]]; then
    # /home/claude/.claude is a named volume whose contents were created
    # under the old uid/gid; reassert ownership so the (possibly remapped)
    # claude user still owns its own state.
    chown -R claude:claude /home/claude
    echo "[entrypoint] remapped claude to uid=$(id -u claude) gid=$(id -g claude) (was uid=$current_uid)"
  fi
}

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

  # Use the `claude` name, not a literal uid: remap_user_to_host may already
  # have moved it off 1000, and the name always resolves to whatever it is
  # now (see remap_user_to_host's comment on why the name is stable).
  [[ -n "${SKIP_CHOWN:-}" ]] || chown -R claude:claude "$STATE_DIR"
  : > "$sentinel"
  [[ -n "${SKIP_CHOWN:-}" ]] || chown claude:claude "$sentinel"
}

# Re-assert the generated settings on EVERY start, so a plugin the agent
# enables mid-session does not survive a restart.
install_sandbox_settings() {
  [[ -r "$SANDBOX_SETTINGS" ]] || return 0
  cp "$SANDBOX_SETTINGS" "$STATE_DIR/settings.json" || {
    echo "[entrypoint] WARNING: could not install sandbox settings" >&2
    return 0
  }
  [[ -n "${SKIP_CHOWN:-}" ]] || chown claude:claude "$STATE_DIR/settings.json"
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
    remap_user_to_host
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
