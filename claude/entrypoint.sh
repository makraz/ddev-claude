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

if [[ "$(id -u)" -eq 0 ]]; then
  # Persist the host-set EXTRA_ALLOWED_DOMAINS into a root-owned file that
  # init-firewall.sh reads. This is the ONLY trusted channel for runtime
  # domains: it runs as genuine root with the compose-provided env, which the
  # unprivileged agent cannot influence. (Crucially, init-firewall.sh no longer
  # reads EXTRA_ALLOWED_DOMAINS from its own env, so the agent cannot inject
  # domains by exporting the var and re-running the firewall via sudo.)
  RUNTIME_LIST=/etc/claude-firewall/runtime-domains.list
  mkdir -p /etc/claude-firewall
  : > "$RUNTIME_LIST"
  chmod 0644 "$RUNTIME_LIST"
  if [[ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]]; then
    # shellcheck disable=SC2086
    for d in ${EXTRA_ALLOWED_DOMAINS}; do
      printf '%s\n' "$d" >> "$RUNTIME_LIST"
    done
  fi

  if /usr/local/bin/init-firewall.sh; then
    echo "[entrypoint] firewall active"
  else
    # Non-fatal: keep the container up so the user can inspect it. The
    # firewall is re-asserted (idempotently) by the `ddev claude` host
    # command, so a transient start-time failure (e.g. sibling not ready)
    # self-heals on the next invocation.
    echo "[entrypoint] WARNING: firewall init failed; will retry on 'ddev claude'" >&2
  fi
else
  echo "[entrypoint] WARNING: not running as root; cannot activate firewall" >&2
fi

exec sleep infinity