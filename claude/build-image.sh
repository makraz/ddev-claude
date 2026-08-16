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
OUT_TOOLS="$ADDON_DIR/tools.list"
OUT_SETTINGS="$ADDON_DIR/settings.json"
OUT_MOUNTS="$DDEV_DIR/docker-compose.claude-mounts.yaml"
OUT_MOUNT_MODE="$ADDON_DIR/.mount-mode"
RESOLVED_MOUNT=""
STAMP="$ADDON_DIR/.build-stamp"

die() { echo "build-image: error: $*" >&2; exit 1; }
log() { echo "build-image: $*"; }

# Hash a file (or stdin, if no args), preferring sha256sum and falling back to
# shasum -a 256 (e.g. on macOS hosts where coreutils isn't installed).
_sha() { sha256sum "$@" 2>/dev/null || shasum -a 256 "$@"; }

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

[[ -f "$BASE_DOCKERFILE" ]] || die "missing $BASE_DOCKERFILE"

# Globals populated by parse_claude_yaml / discover_extras.
EXTRAS=()
EXTRA_DOMAINS_LIST=()
AVAILABLE_EXTRAS=()
TOOLS=()
PLUGINS=()
MOUNT_MODE="auto"

# Shipped defaults, applied when the corresponding key is absent entirely.
DEFAULT_TOOLS=(Read Write Bash Skill)
DEFAULT_PLUGINS=(superpowers code-review gitlab code-simplifier)
DEFAULT_MARKETPLACE="claude-plugins-official"

# Built-in tool names known to this release. Used for typo warnings only —
# never to reject, because the built-in set changes between Claude Code
# releases and a hard-coded list would break on a newer CLI.
KNOWN_TOOLS=(
  Bash BashOutput Edit ExitPlanMode Glob Grep KillShell NotebookEdit
  Read Skill SlashCommand Task TodoWrite WebFetch WebSearch Write
)

# Populate AVAILABLE_EXTRAS from the *.fragment files in the extras dir.
discover_extras() {
  AVAILABLE_EXTRAS=()
  [[ -d "$EXTRAS_DIR" ]] || return 0
  local f
  for f in "$EXTRAS_DIR"/*.fragment; do
    [[ -f "$f" ]] || continue
    AVAILABLE_EXTRAS+=("$(basename "$f" .fragment)")
  done
}

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
        extras)                current_key=extras ;;
        extra_allowed_domains) current_key=extra_domains ;;
        tools)                 current_key=tools ;;
        plugins)               current_key=plugins ;;
        *) die "unknown key '$key' in $file (line $line_no; allowed: extras, extra_allowed_domains, tools, plugins, mount_mode)" ;;
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
        tools)         TOOLS+=("$val") ;;
        plugins)       PLUGINS+=("$val") ;;
        *) die "list item without parent key in $file at line $line_no" ;;
      esac
      continue
    fi

    if [[ "$line" =~ ^([a-zA-Z_]+):[[:space:]]*(.+)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      val="${val#\"}"; val="${val%\"}"
      val="${val#\'}"; val="${val%\'}"
      case "$key" in
        mount_mode)
          MOUNT_MODE="$val"
          current_key=""
          ;;
        extras|extra_allowed_domains|tools|plugins)
          die "key '$key' expects a block list, got scalar value in $file at line $line_no" ;;
        *)
          die "unknown key '$key' in $file (line $line_no; allowed: extras, extra_allowed_domains, tools, plugins, mount_mode)" ;;
      esac
      continue
    fi

    die "failed to parse $file at line $line_no: '$raw'"
  done < "$file"
}

validate_extras() {
  local e
  for e in "${EXTRAS[@]+"${EXTRAS[@]}"}"; do
    _in_array "$e" "${AVAILABLE_EXTRAS[@]+"${AVAILABLE_EXTRAS[@]}"}" \
      || die "unknown extra '$e' (available: ${AVAILABLE_EXTRAS[*]:-<none>})"
  done
}

validate_mount_mode() {
  case "$MOUNT_MODE" in
    auto|mutagen|bind) ;;
    *) die "invalid mount_mode '$MOUNT_MODE' (allowed: auto, mutagen, bind)" ;;
  esac
}

# Unrecognised names warn and pass through — see KNOWN_TOOLS.
validate_tools() {
  local t
  for t in "${TOOLS[@]+"${TOOLS[@]}"}"; do
    [[ "$t" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] \
      || die "invalid tool name '$t' (expected an identifier such as Read)"
    _in_array "$t" "${KNOWN_TOOLS[@]}" \
      || log "warning: unrecognised tool '$t' — passing through to the claude CLI"
  done
}

validate_plugins() {
  local p
  for p in "${PLUGINS[@]+"${PLUGINS[@]}"}"; do
    [[ "$p" =~ ^[A-Za-z0-9_.-]+(@[A-Za-z0-9_.-]+)?$ ]] \
      || die "invalid plugin '$p' (expected name or name@marketplace)"
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

  local dep
  while IFS= read -r dep; do
    _in_array "$dep" "${AVAILABLE_EXTRAS[@]+"${AVAILABLE_EXTRAS[@]}"}" \
      || die "extra '$name' requires unknown extra '$dep'"
    _visit_extra "$dep"
  done < <(read_list_file "$EXTRAS_DIR/${name}.requires")

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
      _sha "$EXTRAS_DIR/${e}.fragment"
      [[ -f "$EXTRAS_DIR/${e}.domains" ]] && _sha "$EXTRAS_DIR/${e}.domains" || :
    done
    _sha "$BASE_DOCKERFILE"
    [[ -f "$LOCAL_DIR/Dockerfile.fragment" ]] && _sha "$LOCAL_DIR/Dockerfile.fragment" || :
    [[ -f "$LOCAL_DIR/extra-domains.list" ]] && _sha "$LOCAL_DIR/extra-domains.list" || :
    printf '%s\n' "tools:${TOOLS[*]+"${TOOLS[*]}"}"
    printf '%s\n' "plugins:${PLUGINS[*]+"${PLUGINS[*]}"}"
    printf '%s\n' "mount:${RESOLVED_MOUNT}"
  } | _sha | awk '{print $1}'
}

stamp_matches() {
  [[ -f "$STAMP" ]] || return 1
  [[ -f "$OUT_DOCKERFILE" ]] || return 1
  [[ -f "$OUT_DOMAINS" ]] || return 1
  [[ -f "$OUT_TOOLS" ]] || return 1
  [[ -f "$OUT_SETTINGS" ]] || return 1
  [[ -f "$OUT_MOUNTS" ]] || return 1
  local now then
  now="$(compute_stamp)"
  then="$(cat "$STAMP")"
  [[ "$now" == "$then" ]]
}

write_stamp() {
  compute_stamp > "$STAMP"
}

# Absent key means the shipped default, not "unrestricted" — install.yaml does
# not ship claude.yaml, so a missing key is the common case on a fresh install.
apply_defaults() {
  [[ ${#TOOLS[@]}   -eq 0 ]] && TOOLS=("${DEFAULT_TOOLS[@]}")
  [[ ${#PLUGINS[@]} -eq 0 ]] && PLUGINS=("${DEFAULT_PLUGINS[@]}")
  return 0
}

# Echo the value of an uncommented top-level `performance_mode:` key, or
# nothing. Anchored at column 0, so commented lines never match.
read_performance_mode() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  sed -n 's/^performance_mode:[[:space:]]*"\{0,1\}\([A-Za-z]*\)"\{0,1\}[[:space:]]*$/\1/p' "$f" | tail -1
}

# Resolution order mirrors DDEV's own: claude.yaml → project config →
# global config → OS default.
#
# We deliberately do NOT probe for the external Mutagen volume here. DDEV
# creates it during start, after this pre-start hook runs, so a first-ever
# `ddev start` would always see it missing and wrongly emit the bind mount.
# Referencing it as external is exactly as safe as DDEV's own generated
# compose, which declares the same volume the same way.
resolve_mount_mode() {
  if [[ "$MOUNT_MODE" != "auto" ]]; then
    RESOLVED_MOUNT="$MOUNT_MODE"
    return 0
  fi

  local pm
  pm="$(read_performance_mode "$DDEV_DIR/config.yaml")"
  [[ -z "$pm" ]] && pm="$(read_performance_mode "${DDEV_GLOBAL_DIR:-$HOME/.ddev}/global_config.yaml")"
  if [[ -z "$pm" ]]; then
    case "$(uname -s)" in
      Darwin|MINGW*|MSYS*|CYGWIN*) pm="mutagen" ;;
      *)                           pm="none" ;;
    esac
  fi

  if [[ "$pm" == "mutagen" ]]; then
    RESOLVED_MOUNT="mutagen"
  else
    RESOLVED_MOUNT="bind"
  fi
}

# Change C: main calls resolve_extras + uses RESOLVED_EXTRAS; stamp no-op
main() {
  parse_claude_yaml "$CONFIG_FILE"
  discover_extras
  validate_extras
  validate_mount_mode
  validate_tools
  validate_plugins
  apply_defaults
  resolve_mount_mode
  resolve_extras

  if stamp_matches; then
    log "inputs unchanged; skipping regeneration."
    exit 0
  fi

  generate_dockerfile
  generate_domains_list
  generate_tools_list
  generate_settings_json
  generate_mounts_override
  write_stamp

  log "wrote $OUT_DOCKERFILE, $OUT_DOMAINS, $OUT_TOOLS, $OUT_SETTINGS and $OUT_MOUNTS (extras: ${RESOLVED_EXTRAS[*]+"${RESOLVED_EXTRAS[*]}"}; mount: ${RESOLVED_MOUNT})"
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
    read_list_file "$EXTRAS_DIR/${e}.domains" >> "$OUT_DOMAINS"
  done
  read_list_file "$LOCAL_DIR/extra-domains.list" >> "$OUT_DOMAINS"
  for d in "${EXTRA_DOMAINS_LIST[@]+"${EXTRA_DOMAINS_LIST[@]}"}"; do
    echo "$d" >> "$OUT_DOMAINS"
  done

  # Dedup, preserving first occurrence order.
  awk '!seen[$0]++' "$OUT_DOMAINS" > "${OUT_DOMAINS}.tmp" && mv "${OUT_DOMAINS}.tmp" "$OUT_DOMAINS"
}

generate_tools_list() {
  local t
  : > "$OUT_TOOLS"
  for t in "${TOOLS[@]+"${TOOLS[@]}"}"; do
    printf '%s\n' "$t" >> "$OUT_TOOLS"
  done
}

generate_settings_json() {
  local p name mkt first=1
  {
    printf '{\n'
    printf '  "enabledPlugins": {\n'
    for p in "${PLUGINS[@]+"${PLUGINS[@]}"}"; do
      name="${p%%@*}"
      mkt="${p#*@}"
      [[ "$mkt" == "$p" ]] && mkt="$DEFAULT_MARKETPLACE"
      [[ $first -eq 0 ]] && printf ',\n'
      printf '    "%s@%s": true' "$name" "$mkt"
      first=0
    done
    [[ $first -eq 0 ]] && printf '\n'
    printf '  }\n'
    printf '}\n'
  } > "$OUT_SETTINGS"
}

generate_mounts_override() {
  {
    echo '#ddev-generated'
    echo '# Mount topology for the claude sidecar. Regenerated at every pre-start'
    echo "# by build-image.sh. Resolved mount mode: ${RESOLVED_MOUNT}."
    echo 'services:'
    echo '    claude:'
    echo '        volumes:'
    if [[ "$RESOLVED_MOUNT" == "mutagen" ]]; then
      echo '            - type: volume'
      echo '              source: project_mutagen'
      echo '              target: /var/www'
      echo '              volume:'
      echo '                  nocopy: true'
      echo '            - ../.git:/var/www/html/.git'
    else
      echo '            - ../:/var/www/html'
    fi
    echo '            - ../.ddev:/mnt/ddev_config:ro'
    echo '            - type: volume'
    echo '              source: claude_state'
    echo '              target: /home/claude/.claude'
    echo 'volumes:'
    if [[ "$RESOLVED_MOUNT" == "mutagen" ]]; then
      echo '    project_mutagen:'
      echo '        name: ${DDEV_SITENAME}_project_mutagen'
      echo '        external: true'
    fi
    echo '    claude_state:'
    echo '        name: ${DDEV_SITENAME}_claude_state'
  } > "$OUT_MOUNTS"

  printf '%s\n' "$RESOLVED_MOUNT" > "$OUT_MOUNT_MODE"
}

main "$@"
