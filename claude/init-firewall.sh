#!/usr/bin/env bash
#ddev-generated
#
# init-firewall.sh — ddev claude sidecar firewall
# ------------------------------------------------
# Lock down outbound network access for the Claude Code sandbox.
#
# Allowed outbound destinations:
#   - github.com, api.github.com            (git, releases)
#   - anthropic.com, claude.ai              (Claude Code API + OAuth)
#   - downloads.claude.ai                   (claude update / installer)
#   - Host gateway IP                       (ddev host talking in)
#   - Local docker-compose subnets          (sibling ddev services)
# Additional domains contributed by enabled extras (e.g. packagist.org for
# the `php` extra) and `extra_allowed_domains` in .ddev/claude.yaml come in
# via the build-baked /etc/claude-firewall/extra-domains.list.
#
# Allowed inbound:
#   - Anything from the host gateway IP
#   - TCP 80, 443 and UDP 443 (HTTP/3) from any source
#
# Extend via (root-owned files only; see the Allow-list section below):
#   - extra_allowed_domains in .ddev/claude.yaml, then `ddev claude rebuild`
#   - EXTRA_ALLOWED_DOMAINS on the host before `ddev start` (persisted to
#     /etc/claude-firewall/runtime-domains.list by entrypoint.sh)
#
# Must be run as root. Requires NET_ADMIN + NET_RAW on the container,
# which are granted by .ddev/docker-compose.claude.yaml.
#
set -euo pipefail
IFS=$'\n\t'

log()  { printf '\033[1;34m[firewall]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[firewall]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[firewall]\033[0m %s\n' "$*" >&2; exit 1; }

# Emit cleaned entries from a list file on stdout: strip `#` comments, trim
# surrounding whitespace, drop blank lines. No-op when the file is absent.
read_list_file() {
  local file="$1" line
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -n "$line" ]] && printf '%s\n' "$line"
  done < "$file"
  return 0
}

[[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0)"

# ---------------------------------------------------------------------------
# Mode
# ---------------------------------------------------------------------------
# full    (default) — flush + rebuild all rules, resolve domains, smoke-test.
# --ensure          — idempotent re-assert used by the `ddev claude` host
#                     command on every invocation. If the firewall is already
#                     healthy it exits immediately, skipping the full reset,
#                     per-domain DNS resolution, and the curl smoke tests (the
#                     expensive parts). The full firewall still runs at
#                     container start (entrypoint.sh) and whenever the health
#                     check fails, so a transient start-time failure self-heals
#                     on the next `ddev claude`.
MODE="full"
case "${1:-}" in
  --ensure) MODE="ensure" ;;
  "")       ;;
  *)        die "unknown argument: $1 (usage: $0 [--ensure])" ;;
esac

# Written at the end of a successful full run; lives in /run (tmpfs, root-owned,
# cleared on container restart) so the unprivileged agent can neither forge it
# nor have it survive a restart that dropped the rules.
READY_MARKER="/run/claude-firewall.ready"

firewall_healthy() {
  [[ -f "$READY_MARKER" ]] || return 1
  iptables -S OUTPUT 2>/dev/null | grep -q -- '-P OUTPUT DROP' || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Allow-list
# ---------------------------------------------------------------------------
DEFAULT_DOMAINS=(
  "github.com"
  "api.github.com"
  "anthropic.com"
  "claude.ai"
  "downloads.claude.ai"
)

# Allow-list sources are ROOT-OWNED files OUTSIDE the bind-mounted project
# tree, so the unprivileged `claude` user (uid 1000 in the base image; remapped to the
# host's uid at container start by entrypoint.sh) cannot edit them and
# re-run this script to widen its own egress:
#   - extra-domains.list   : baked into the image at build from .ddev/claude.yaml
#   - runtime-domains.list : written at container start by entrypoint.sh from
#                            the trusted host-set EXTRA_ALLOWED_DOMAINS
# We deliberately do NOT read EXTRA_ALLOWED_DOMAINS from this script's own
# environment: on the `sudo init-firewall.sh` path the agent could otherwise
# export it in its own shell and inject domains.
EXTRA_DOMAINS=()
EXTRA_FILES=(
  "/etc/claude-firewall/extra-domains.list"     # build-baked (from claude.yaml)
  "/etc/claude-firewall/runtime-domains.list"   # start-time (from EXTRA_ALLOWED_DOMAINS)
  "/etc/firewall/extra-domains.list"            # legacy fallback
)
for EXTRA_FILE in "${EXTRA_FILES[@]}"; do
  while IFS= read -r line; do
    EXTRA_DOMAINS+=("$line")
  done < <(read_list_file "$EXTRA_FILE")
done
ALL_DOMAINS=( "${DEFAULT_DOMAINS[@]}" "${EXTRA_DOMAINS[@]}" )
log "allow-listed domains: ${ALL_DOMAINS[*]}"

# ddev sibling-service hostnames, used for the dnsmasq static address records
# below. This is NOT a security boundary: Docker's embedded DNS (127.0.0.11,
# the dnsmasq upstream) already resolves every sibling, and the whole docker
# subnet is allowed via the `allowed-net` ipset regardless. The list only seeds
# convenience records, and we self-prune to names that actually resolve — so
# listing a service that doesn't exist is harmless, and missing one costs only
# a static record (the name still resolves via the upstream). It is therefore
# safe to read from the environment here (unlike the egress allow-list): an
# override cannot widen egress. Override for non-standard stacks via
# DDEV_CLAUDE_SIBLING_HOSTS (space-separated). The default covers the common
# ddev services; `web` is always present.
IFS=' ' read -r -a SIBLING_HOSTS <<< "${DDEV_CLAUDE_SIBLING_HOSTS:-web db mailpit}"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
command -v iptables >/dev/null || die "iptables not installed"
command -v ipset    >/dev/null || die "ipset not installed"
command -v dig      >/dev/null || die "dig not installed"
command -v dnsmasq  >/dev/null || warn "dnsmasq missing — CDN rotation will break"

# ---------------------------------------------------------------------------
# Fast path: skip the full rebuild when already healthy (--ensure only)
# ---------------------------------------------------------------------------
if [[ "$MODE" == "ensure" ]] && firewall_healthy; then
  log "firewall already active; skipping re-init (--ensure)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Reset any prior state (idempotent)
# ---------------------------------------------------------------------------
log "resetting existing rules"
# Only flush the `filter` table (INPUT/OUTPUT/FORWARD) — the only table this
# script actually writes to. Do NOT touch `nat` or `mangle`: Docker installs
# a DNAT rule in nat/DOCKER_OUTPUT that redirects 127.0.0.11:53 to the real
# embedded DNS, and flushing nat silently deletes that rule, leaving every
# internal hostname (`web`, `db`, `mailpit`) unresolvable until container
# restart. The script never adds any nat/mangle rules, so there's nothing
# to clean up in those tables anyway.
iptables -F            || true
iptables -X            || true
ipset destroy allowed-ipv4 2>/dev/null || true
ipset destroy allowed-net  2>/dev/null || true

# ---------------------------------------------------------------------------
# Create ipsets
# ---------------------------------------------------------------------------
ipset create allowed-ipv4 hash:ip  family inet maxelem 65536
ipset create allowed-net  hash:net family inet maxelem 1024

# ---------------------------------------------------------------------------
# Host gateway
# ---------------------------------------------------------------------------
HOST_GATEWAY="$(ip route | awk '/default/ {print $3; exit}')"
[[ -n "$HOST_GATEWAY" ]] || die "could not determine host gateway IP"
log "host gateway: $HOST_GATEWAY"
ipset add allowed-ipv4 "$HOST_GATEWAY" 2>/dev/null || true

# ---------------------------------------------------------------------------
# DNS upstreams — the ONLY destinations allowed on port 53.
#
# Declared once and consumed twice: by the iptables rules below and by the
# generated dnsmasq config further down. Keeping one list is the point — if the
# two drifted, either DNS would break or port 53 would stay wider than the
# resolvers actually in use.
#
# 127.0.0.11 (Docker's embedded DNS) is reached over loopback, which already has
# a blanket ACCEPT, so it needs no port-53 rule of its own; it is listed here
# only because dnsmasq needs it as a `server=`.
DNS_UPSTREAMS=(
  "127.0.0.11"
  "$HOST_GATEWAY"
  "1.1.1.1"
  "8.8.8.8"
)

# ---------------------------------------------------------------------------
# Local docker subnets — detect every non-default route and allow it.
# This catches ddev's internal network so the sidecar can reach `web`,
# `db`, `mailpit`, etc. without hardcoding subnets.
# ---------------------------------------------------------------------------
log "detecting local docker networks"
while IFS= read -r cidr; do
  [[ -z "$cidr" ]] && continue
  log "  local network: $cidr"
  ipset add allowed-net "$cidr" 2>/dev/null || true
done < <(ip -4 route show | awk '!/default/ && /src/ {print $1}' | grep -E '^[0-9]')

# ===========================================================================
# iptables rules
#
# Installed BEFORE dnsmasq setup and the initial DNS resolution: on a re-run
# the DROP policies persist from the previous run while the ACCEPT rules were
# just flushed, so nothing — not even loopback or port-53 — would resolve
# until these rules are back. (On a fresh container the policies are still
# ACCEPT, which is why this ordering bug only ever bit re-runs.)
# ===========================================================================
log "installing iptables rules"

iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# Loopback
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Stateful connection tracking
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DNS — restricted to the known upstreams, NOT open to every host.
#
# A blanket `--dport 53 -j ACCEPT` (which this was until v0.4.0) is a full
# bidirectional egress channel to any host listening on 53: DNS tunnelling, or
# just a raw socket to attacker:53. That defeated the allow-list for anyone
# willing to run a resolver. Everything else still goes through the ipset.
for _ns in "${DNS_UPSTREAMS[@]}"; do
  [[ -n "$_ns" ]] || continue
  # Loopback (127/8, incl. Docker's 127.0.0.11) is already accepted above.
  case "$_ns" in 127.*) continue ;; esac
  iptables -A OUTPUT -p udp -d "$_ns" --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp -d "$_ns" --dport 53 -j ACCEPT
done
unset _ns

# Outbound allow-list (domain IPs, populated by dnsmasq)
iptables -A OUTPUT -m set --match-set allowed-ipv4 dst -j ACCEPT

# Local docker subnets (ddev sibling services: web, db, mailpit, ...)
iptables -A OUTPUT -m set --match-set allowed-net  dst -j ACCEPT
iptables -A INPUT  -m set --match-set allowed-net  src -j ACCEPT

# Host gateway in (ddev tooling, health checks)
iptables -A INPUT -s "$HOST_GATEWAY" -j ACCEPT

# Public inbound (if you want the sidecar to serve anything)
iptables -A INPUT -p tcp --dport 80  -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j ACCEPT

# ICMP (ping for debugging)
iptables -A OUTPUT -p icmp --icmp-type echo-request -j ACCEPT
iptables -A INPUT  -p icmp --icmp-type echo-reply   -j ACCEPT

# Terminal REJECT on OUTPUT: make a blocked connection fail, not hang.
#
# `-P OUTPUT DROP` on its own black-holes blocked egress — the packet is
# swallowed with no RST and no ICMP, so the client waits out its full connect
# timeout. DNS still resolves (port 53 is open to the upstreams above), so a
# client happily commits to a connection that will never be answered. The cost
# is per attempt and paid by whatever the agent runs: curl defaults to a 300s
# connect timeout, and a package manager or test suite that touches a
# non-allow-listed host multiplies that by every request it makes.
#
# These two rules sit last in OUTPUT, so anything an earlier ACCEPT matched is
# unaffected. This does NOT widen egress by a single address — the allow-list
# above is untouched. It only changes *how* a blocked connection fails:
# immediately, with ECONNREFUSED, instead of hanging. The DROP policy stays as
# the backstop in case these rules are ever flushed without the policy being
# reset.
iptables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
iptables -A OUTPUT -j REJECT --reject-with icmp-port-unreachable

# IPv6 -> drop entirely.
#
# If ip6tables is unavailable we cannot filter v6. That's only safe when the
# container has no IPv6 egress path; if a v6 default route exists we would be
# leaving an unfiltered escape channel, so fail loudly rather than silently
# skip (the whole point of this script is that there is no unfiltered egress).
if command -v ip6tables >/dev/null; then
  ip6tables -P INPUT   DROP || true
  ip6tables -P FORWARD DROP || true
  ip6tables -P OUTPUT  DROP || true
  ip6tables -F || true
  ip6tables -A INPUT  -i lo -j ACCEPT || true
  ip6tables -A OUTPUT -o lo -j ACCEPT || true
  ip6tables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
  ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
  # Same fast-fail reasoning as the IPv4 REJECT above. External names still
  # return AAAA records, so a client that prefers IPv6 would otherwise hang on
  # the v6 attempt before falling back to v4.
  ip6tables -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset || true
  ip6tables -A OUTPUT -j REJECT --reject-with icmp6-port-unreachable || true
elif ip -6 route show default 2>/dev/null | grep -q .; then
  die "ip6tables not installed but an IPv6 default route exists — cannot filter IPv6 egress. Rebuild the base image with ip6tables, or disable IPv6 on the container."
else
  log "no ip6tables and no IPv6 default route; IPv6 lockdown not needed"
fi

# ---------------------------------------------------------------------------
# dnsmasq: dynamic DNS -> ipset bridge.
#
# Upstream is set to 127.0.0.11 (Docker's embedded DNS) so ddev's internal
# service names (`web`, `db`, `mailpit`, `*.ddev.site`) still resolve,
# with public resolvers as a fallback for external domains.
# ---------------------------------------------------------------------------
if command -v dnsmasq >/dev/null; then
  DNSMASQ_CONF="/etc/dnsmasq.d/claude-firewall.conf"
  mkdir -p /etc/dnsmasq.d
  {
    echo "# Generated by init-firewall.sh"
    echo "listen-address=127.0.0.1"
    echo "bind-interfaces"
    echo "no-resolv"
    # Same list the port-53 iptables rules were built from — see DNS_UPSTREAMS.
    for _ns in "${DNS_UPSTREAMS[@]}"; do
      [[ -n "$_ns" ]] && echo "server=${_ns}"
    done
    for d in "${ALL_DOMAINS[@]}"; do
      echo "ipset=/${d}/allowed-ipv4"
    done
    # Static address records for Docker-internal service hostnames (self-pruning:
    # only names that currently resolve get a record).
    for svc in "${SIBLING_HOSTS[@]}"; do
      svc_ip=$(dig @127.0.0.11 +short +time=2 +tries=1 A "$svc" 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)
      if [[ -n "$svc_ip" ]]; then
        echo "address=/${svc}/${svc_ip}"
      fi
    done
  } > "$DNSMASQ_CONF"

  pkill -x dnsmasq 2>/dev/null || true
  dnsmasq --conf-file="$DNSMASQ_CONF" || warn "dnsmasq failed to start"

  {
    echo "nameserver 127.0.0.1"
    echo "nameserver 127.0.0.11"
  } > /etc/resolv.conf
  log "dnsmasq running; resolv.conf -> 127.0.0.1"
fi

# ---------------------------------------------------------------------------
# Initial DNS resolution — seed the ipset so allow-listed domains work
# immediately, without waiting for a first lookup through dnsmasq. Runs last:
# under the now-installed DROP policy only port 53 (+ loopback) is open, which
# is exactly what dig needs. These queries go through dnsmasq, so they also
# warm its cache.
# ---------------------------------------------------------------------------
resolve_and_add() {
  local domain="$1" ips
  ips=$(dig +short +time=3 +tries=2 A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' || true)
  if [[ -z "$ips" ]]; then
    warn "no A records for $domain (will populate via dnsmasq)"
    return
  fi
  while IFS= read -r ip; do
    ipset add allowed-ipv4 "$ip" 2>/dev/null || true
  done <<< "$ips"
}
log "performing initial DNS resolution"
for d in "${ALL_DOMAINS[@]}"; do resolve_and_add "$d"; done

# ===========================================================================
# Smoke tests — fail loud if something is obviously wrong.
# ===========================================================================
log "running smoke tests"

test_allowed() {
  local url="$1" code
  code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo 000)
  if [[ "$code" =~ ^[23] ]]; then
    log "  ✓ $url reachable ($code)"
  else
    warn "  ✗ $url NOT reachable ($code) — check allow-list / dnsmasq"
  fi
}

test_blocked() {
  local url="$1"
  if curl -sS --max-time 3 -o /dev/null "$url" 2>/dev/null; then
    warn "  ✗ $url REACHABLE (should be blocked!)"
  else
    log "  ✓ $url correctly blocked"
  fi
}

test_allowed  "https://api.github.com"

# example.com doubles as the canonical blocked-probe AND a domain projects may
# legitimately allow-list (our own tests do) — only assert blockage when it
# isn't allow-listed.
example_allowed=0
for d in "${ALL_DOMAINS[@]}"; do [[ "$d" == "example.com" ]] && example_allowed=1; done
if [[ $example_allowed -eq 0 ]]; then
  test_blocked "https://example.com"
else
  log "  - skipping blocked-probe: example.com is allow-listed in this project"
fi

# ddev sibling reachability check (not fatal — the sibling may be down)
if getent hosts web >/dev/null 2>&1; then
  if (echo > /dev/tcp/web/80) >/dev/null 2>&1; then
    log "  ✓ ddev 'web' sibling reachable on port 80"
  else
    warn "  ✗ ddev 'web' sibling NOT reachable — check allowed-net rule"
  fi
fi

# Mark the firewall healthy so a subsequent `--ensure` re-assert can fast-path.
# Reached only after the full rule set is installed (smoke tests warn but never
# abort, so a warning here still means the rules are in place).
: > "$READY_MARKER"

log "firewall ready"
