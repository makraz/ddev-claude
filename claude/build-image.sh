#!/usr/bin/env bash
#ddev-generated
#
# build-image.sh — assemble the per-project sidecar Dockerfile.
#
# Reads:
#   - .ddev/claude.yaml             (per-project config; extras + extra_allowed_domains)
#   - .ddev/claude/Dockerfile.base  (template with {{EXTRAS}} marker)
#   - .ddev/claude/extras/*.fragment, *.domains, *.requires
#   - .ddev/claude.local/Dockerfile.fragment (optional escape hatch)
#   - .ddev/claude.local/extra-domains.list  (optional escape hatch)
#
# Writes:
#   - .ddev/claude/Dockerfile           (used by docker-compose)
#   - .ddev/claude/extra-domains.list   (read by init-firewall.sh inside the sidecar)
#   - .ddev/claude/.build-stamp         (input-hash → skip work when unchanged)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_DIR="$SCRIPT_DIR"
DDEV_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$DDEV_DIR/claude.yaml"
LOCAL_DIR="$DDEV_DIR/claude.local"
EXTRAS_DIR="$ADDON_DIR/extras"
BASE_DOCKERFILE="$ADDON_DIR/Dockerfile.base"
OUT_DOCKERFILE="$ADDON_DIR/Dockerfile"
OUT_DOMAINS="$ADDON_DIR/extra-domains.list"
STAMP="$ADDON_DIR/.build-stamp"

die() { echo "build-image: error: $*" >&2; exit 1; }
log() { echo "build-image: $*"; }

[[ -f "$BASE_DOCKERFILE" ]] || die "missing $BASE_DOCKERFILE"

# Globals populated by parse_claude_yaml.
EXTRAS=()
EXTRA_DOMAINS_LIST=()

parse_claude_yaml() {
  local file="$1"
  [[ -f "$file" ]] || return 0   # absent = empty config
  local current_key=""
  local line_no=0 raw line key val

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_no=$((line_no + 1))
    line="${raw%%#*}"
    # trim trailing whitespace
    while [[ "$line" =~ [[:space:]]$ ]]; do line="${line%[[:space:]]}"; done
    [[ -z "$line" ]] && continue

    # Change A: accept empty-list shorthand `key: []`
    if [[ "$line" =~ ^([a-zA-Z_]+):[[:space:]]*(\[[[:space:]]*\])?[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[1]}"
      case "$key" in
        extras)               current_key=extras ;;
        extra_allowed_domains) current_key=extra_domains ;;
        *) die "unknown key '$key' in $file (line $line_no; allowed: extras, extra_allowed_domains)" ;;
      esac
      # `key: []` is the empty-list shorthand — no further items; reset current_key
      # so any subsequent indented list items would be detected as a parse error.
      if [[ "${BASH_REMATCH[2]:-}" == *"["* ]]; then
        current_key=""
      fi
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]+-[[:space:]]*(.+)$ ]]; then
      val="${BASH_REMATCH[1]}"
      val="${val#\"}"; val="${val%\"}"
      val="${val#\'}"; val="${val%\'}"
      case "$current_key" in
        extras)        EXTRAS+=("$val") ;;
        extra_domains) EXTRA_DOMAINS_LIST+=("$val") ;;
        *) die "list item without parent key in $file at line $line_no" ;;
      esac
      continue
    fi

    die "failed to parse $file at line $line_no: '$raw'"
  done < "$file"
}

validate_extras() {
  local available=()
  if [[ -d "$EXTRAS_DIR" ]]; then
    local f
    for f in "$EXTRAS_DIR"/*.fragment; do
      [[ -f "$f" ]] || continue
      available+=("$(basename "$f" .fragment)")
    done
  fi
  local e found a
  for e in "${EXTRAS[@]+"${EXTRAS[@]}"}"; do
    found=0
    for a in "${available[@]+"${available[@]}"}"; do
      [[ "$a" == "$e" ]] && found=1 && break
    done
    [[ $found -eq 1 ]] || die "unknown extra '$e' (available: ${available[*]:-<none>})"
  done
}

# Change B: .requires topological resolver
# RESOLVED_EXTRAS is filled in resolution order: dependencies before dependents.
RESOLVED_EXTRAS=()
_VISITING=()
_VISITED=()

_in_array() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

_visit_extra() {
  local name="$1"
  _in_array "$name" "${_VISITED[@]+"${_VISITED[@]}"}" && return 0
  _in_array "$name" "${_VISITING[@]+"${_VISITING[@]}"}" && {
    local chain
    chain="$(printf '%s -> ' "${_VISITING[@]}")"
    die "dependency cycle in extras: ${chain}${name}"
  }
  _VISITING+=("$name")

  local req_file="$EXTRAS_DIR/${name}.requires"
  if [[ -f "$req_file" ]]; then
    local dep
    while IFS= read -r dep || [[ -n "$dep" ]]; do
      dep="${dep%%#*}"
      dep="$(echo "$dep" | xargs)"
      [[ -z "$dep" ]] && continue
      _in_array "$dep" $(ls "$EXTRAS_DIR" 2>/dev/null | sed -n 's/\.fragment$//p') \
        || die "extra '$name' requires unknown extra '$dep'"
      _visit_extra "$dep"
    done < "$req_file"
  fi

  # pop from VISITING (last element), push to VISITED and RESOLVED_EXTRAS
  local last_idx=$(( ${#_VISITING[@]} - 1 ))
  unset "_VISITING[$last_idx]"
  _VISITING=("${_VISITING[@]+"${_VISITING[@]}"}")
  _VISITED+=("$name")
  RESOLVED_EXTRAS+=("$name")
}

resolve_extras() {
  RESOLVED_EXTRAS=()
  _VISITING=()
  _VISITED=()
  local e
  for e in "${EXTRAS[@]+"${EXTRAS[@]}"}"; do
    _visit_extra "$e"
  done
}

# Change D: build stamp helpers
compute_stamp() {
  {
    printf '%s\n' "resolved:${RESOLVED_EXTRAS[*]+"${RESOLVED_EXTRAS[*]}"}"
    printf '%s\n' "domains:${EXTRA_DOMAINS_LIST[*]+"${EXTRA_DOMAINS_LIST[*]}"}"
    local e
    for e in "${RESOLVED_EXTRAS[@]+"${RESOLVED_EXTRAS[@]}"}"; do
      printf 'fragment:%s\n' "$e"
      (sha256sum "$EXTRAS_DIR/${e}.fragment" 2>/dev/null || shasum -a 256 "$EXTRAS_DIR/${e}.fragment")
      if [[ -f "$EXTRAS_DIR/${e}.domains" ]]; then
        (sha256sum "$EXTRAS_DIR/${e}.domains" 2>/dev/null || shasum -a 256 "$EXTRAS_DIR/${e}.domains")
      fi
    done
    (sha256sum "$BASE_DOCKERFILE" 2>/dev/null || shasum -a 256 "$BASE_DOCKERFILE")
    if [[ -f "$LOCAL_DIR/Dockerfile.fragment" ]]; then
      (sha256sum "$LOCAL_DIR/Dockerfile.fragment" 2>/dev/null || shasum -a 256 "$LOCAL_DIR/Dockerfile.fragment")
    fi
    if [[ -f "$LOCAL_DIR/extra-domains.list" ]]; then
      (sha256sum "$LOCAL_DIR/extra-domains.list" 2>/dev/null || shasum -a 256 "$LOCAL_DIR/extra-domains.list")
    fi
  } | (sha256sum 2>/dev/null || shasum -a 256) | awk '{print $1}'
}

stamp_matches() {
  [[ -f "$STAMP" ]] || return 1
  [[ -f "$OUT_DOCKERFILE" ]] || return 1
  [[ -f "$OUT_DOMAINS" ]] || return 1
  local now then
  now="$(compute_stamp)"
  then="$(cat "$STAMP")"
  [[ "$now" == "$then" ]]
}

write_stamp() {
  compute_stamp > "$STAMP"
}

# Change C: main calls resolve_extras + uses RESOLVED_EXTRAS; stamp no-op
main() {
  parse_claude_yaml "$CONFIG_FILE"
  validate_extras
  resolve_extras

  if stamp_matches; then
    log "inputs unchanged; skipping regeneration."
    exit 0
  fi

  generate_dockerfile
  generate_domains_list
  write_stamp

  log "wrote $OUT_DOCKERFILE and $OUT_DOMAINS (extras: ${RESOLVED_EXTRAS[*]+"${RESOLVED_EXTRAS[*]}"})"
}

generate_dockerfile() {
  # Concatenate selected fragments + local fragment, then splice into Dockerfile.base
  # replacing the literal `# {{EXTRAS}}` marker line.
  local tmp_frags
  tmp_frags="$(mktemp)"

  local e first=1
  for e in "${RESOLVED_EXTRAS[@]+"${RESOLVED_EXTRAS[@]}"}"; do
    [[ $first -eq 0 ]] && echo "" >> "$tmp_frags"
    cat "$EXTRAS_DIR/${e}.fragment" >> "$tmp_frags"
    first=0
  done
  if [[ -f "$LOCAL_DIR/Dockerfile.fragment" ]]; then
    [[ $first -eq 0 ]] && echo "" >> "$tmp_frags"
    cat "$LOCAL_DIR/Dockerfile.fragment" >> "$tmp_frags"
  fi

  awk -v frags="$tmp_frags" '
    /^# \{\{EXTRAS\}\}$/ {
      while ((getline line < frags) > 0) print line
      close(frags)
      next
    }
    { print }
  ' "$BASE_DOCKERFILE" > "$OUT_DOCKERFILE"
  rm -f "$tmp_frags"
}

generate_domains_list() {
  : > "$OUT_DOMAINS"
  local e d
  for e in "${RESOLVED_EXTRAS[@]+"${RESOLVED_EXTRAS[@]}"}"; do
    if [[ -f "$EXTRAS_DIR/${e}.domains" ]]; then
      while IFS= read -r d || [[ -n "$d" ]]; do
        d="${d%%#*}"
        d="$(echo "$d" | xargs)"
        [[ -n "$d" ]] && echo "$d" >> "$OUT_DOMAINS"
      done < "$EXTRAS_DIR/${e}.domains"
    fi
  done
  if [[ -f "$LOCAL_DIR/extra-domains.list" ]]; then
    while IFS= read -r d || [[ -n "$d" ]]; do
      d="${d%%#*}"
      d="$(echo "$d" | xargs)"
      [[ -n "$d" ]] && echo "$d" >> "$OUT_DOMAINS"
    done < "$LOCAL_DIR/extra-domains.list"
  fi
  for d in "${EXTRA_DOMAINS_LIST[@]+"${EXTRA_DOMAINS_LIST[@]}"}"; do
    echo "$d" >> "$OUT_DOMAINS"
  done

  # Dedup, preserving first occurrence order.
  awk '!seen[$0]++' "$OUT_DOMAINS" > "${OUT_DOMAINS}.tmp" && mv "${OUT_DOMAINS}.tmp" "$OUT_DOMAINS"
}

main "$@"
