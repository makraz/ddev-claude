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
#   - Host gateway IP                       (ddev host talking in)
#   - Local docker-compose subnets          (sibling ddev services)
# Additional domains contributed by enabled extras (e.g. packagist.org for
# the `php` extra) come in via /var/www/html/.ddev/claude/extra-domains.list.
#
# Allowed inbound:
#   - Anything from the host gateway IP
#   - TCP 80, 443 and UDP 443 (HTTP/3) from any source
#
# Extend via:
#   - EXTRA_ALLOWED_DOMAINS env var (space-separated)
#   - /etc/firewall/extra-domains.list (one per line, # comments ok)
#
# Must be run as root. Requires NET_ADMIN + NET_RAW on the container,
# which are granted by .ddev/docker-compose.claude.yaml.
#
set -euo pipefail
IFS=$'\n\t'

log()  { printf '\033[1;34m[firewall]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[firewall]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[firewall]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0)"

# ---------------------------------------------------------------------------
# Allow-list
# ---------------------------------------------------------------------------
DEFAULT_DOMAINS=(
  "github.com"
  "api.github.com"
  "anthropic.com"
  "claude.ai"
)

EXTRA_DOMAINS=()
EXTRA_FILES=(
  "/var/www/html/.ddev/claude/extra-domains.list"   # build-generated
  "/etc/firewall/extra-domains.list"                # legacy fallback
)
for EXTRA_FILE in "${EXTRA_FILES[@]}"; do
  [[ -f "$EXTRA_FILE" ]] || continue
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -n "$line" ]] && EXTRA_DOMAINS+=("$line")
  done < "$EXTRA_FILE"
done
if [[ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]]; then
  # shellcheck disable=SC2206
  EXTRA_DOMAINS+=( ${EXTRA_ALLOWED_DOMAINS} )
fi
ALL_DOMAINS=( "${DEFAULT_DOMAINS[@]}" "${EXTRA_DOMAINS[@]}" )
log "allow-listed domains: ${ALL_DOMAINS[*]}"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
command -v iptables >/dev/null || die "iptables not installed"
command -v ipset    >/dev/null || die "ipset not installed"
command -v dig      >/dev/null || die "dig not installed"
command -v dnsmasq  >/dev/null || warn "dnsmasq missing — CDN rotation will break"

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
# Initial DNS resolution — gives us a working baseline even if dnsmasq
# hasn't started yet
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

# ---------------------------------------------------------------------------
# Host gateway
# ---------------------------------------------------------------------------
HOST_GATEWAY="$(ip route | awk '/default/ {print $3; exit}')"
[[ -n "$HOST_GATEWAY" ]] || die "could not determine host gateway IP"
log "host gateway: $HOST_GATEWAY"
ipset add allowed-ipv4 "$HOST_GATEWAY" 2>/dev/null || true

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
    echo "server=127.0.0.11"       # Docker embedded DNS (ddev internal)
    echo "server=${HOST_GATEWAY}"  # host fallback
    echo "server=1.1.1.1"          # public fallback
    echo "server=8.8.8.8"
    for d in "${ALL_DOMAINS[@]}"; do
      echo "ipset=/${d}/allowed-ipv4"
    done
    # Static address records for Docker-internal service hostnames
    for svc in web db mailpit; do
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

# ===========================================================================
# iptables rules
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

# DNS (so dnsmasq can reach its upstreams)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

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

# IPv6 -> drop entirely
if command -v ip6tables >/dev/null; then
  ip6tables -P INPUT   DROP || true
  ip6tables -P FORWARD DROP || true
  ip6tables -P OUTPUT  DROP || true
  ip6tables -F || true
  ip6tables -A INPUT  -i lo -j ACCEPT || true
  ip6tables -A OUTPUT -o lo -j ACCEPT || true
  ip6tables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
  ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || true
fi

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
test_blocked  "https://example.com"

# ddev sibling reachability check (not fatal — the sibling may be down)
if getent hosts web >/dev/null 2>&1; then
  if (echo > /dev/tcp/web/80) >/dev/null 2>&1; then
    log "  ✓ ddev 'web' sibling reachable on port 80"
  else
    warn "  ✗ ddev 'web' sibling NOT reachable — check allowed-net rule"
  fi
fi

log "firewall ready"
