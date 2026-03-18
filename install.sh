#!/usr/bin/env bash
set -euo pipefail

APP_NAME="claude-statusline"
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_BIN_DIR="${CLAUDE_DIR}/bin"
TARGET_STATUSLINE="${CLAUDE_DIR}/statusline.sh"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
STATUSLINE_COMMAND="~/.claude/statusline.sh"
RAW_BASE_URL="${CLAUDE_STATUSLINE_RAW_BASE:-https://raw.githubusercontent.com/susomejias/claude-statusline/main}"
REMOTE_STATUSLINE_URL="${CLAUDE_STATUSLINE_SCRIPT_URL:-${RAW_BASE_URL}/statusline.sh}"
JQ_VERSION="${CLAUDE_STATUSLINE_JQ_VERSION:-1.8.1}"
JQ_RELEASE_BASE="${CLAUDE_STATUSLINE_JQ_RELEASE_BASE:-https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}}"
JQ_CHECKSUMS_URL="${CLAUDE_STATUSLINE_JQ_CHECKSUMS_URL:-https://raw.githubusercontent.com/jqlang/jq/master/sig/v${JQ_VERSION}/sha256sum.txt}"
LOCAL_JQ_BIN="${CLAUDE_BIN_DIR}/jq"
SCRIPT_DIR=""
LOCAL_STATUSLINE=""
if [[ -n "${BASH_SOURCE[0]-}" && "${BASH_SOURCE[0]-}" != "-" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LOCAL_STATUSLINE="${SCRIPT_DIR}/statusline.sh"
fi

ASSUME_YES=false
COMMAND="install"
JQ_BIN=""

info() { printf "[INFO] %s\n" "$1" >&2; }
warn() { printf "[WARN] %s\n" "$1" >&2; }
error() { printf "[ERROR] %s\n" "$1" >&2; }

usage() {
  cat <<'USAGE'
Usage: ./install.sh [install|update|uninstall] [--yes]

Commands:
  install   Install or repair claude-statusline (default)
  update    Refresh statusline script and ensure settings are configured
  uninstall Remove installed script and clean statusLine when managed by this installer
  --help    Show this help

Options:
  --yes     Auto-confirm potentially incompatible or overwrite operations
USAGE
}

confirm() {
  local prompt="$1"
  local reply

  if [[ "$ASSUME_YES" == "true" ]]; then
    info "Auto-confirmed (--yes): ${prompt}"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    return 2
  fi

  printf "%s [y/N]: " "$prompt" >&2
  read -r reply || true

  case "$reply" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

require_confirmation_or_exit() {
  local prompt="$1"
  local confirm_status

  if confirm "$prompt"; then
    return 0
  else
    confirm_status=$?
  fi

  case "$confirm_status" in
    1)
      error "Operation cancelled by user."
      exit 1
      ;;
    2)
      error "$prompt"
      error "Run again with --yes to approve this non-interactively."
      exit 1
      ;;
    *)
      error "Operation cancelled."
      exit 1
      ;;
  esac
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    error "This installer currently supports macOS only."
    exit 1
  fi
}

require_base_tools() {
  local cmd
  for cmd in bash curl shasum mktemp uname chmod cp mv cmp awk; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "Missing required tool: ${cmd}. Please install it and retry."
      exit 1
    fi
  done
}

backup_file() {
  local file_path="$1"
  local backup_file

  backup_file="${file_path}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$file_path" "$backup_file"
  info "Backup created: ${backup_file}"
}

prepend_local_bin_to_path() {
  if [[ -d "$CLAUDE_BIN_DIR" ]]; then
    case ":$PATH:" in
      *":$CLAUDE_BIN_DIR:"*) ;;
      *) PATH="$CLAUDE_BIN_DIR:$PATH" ;;
    esac
  fi
}

resolve_jq_in_path() {
  if command -v jq >/dev/null 2>&1; then
    command -v jq
    return
  fi

  if [[ -x "$LOCAL_JQ_BIN" ]]; then
    printf "%s\n" "$LOCAL_JQ_BIN"
    return
  fi

  printf "\n"
}

detect_jq_asset_name() {
  case "$(uname -m)" in
    arm64|aarch64)
      printf "jq-macos-arm64\n"
      ;;
    x86_64|amd64)
      printf "jq-macos-amd64\n"
      ;;
    *)
      error "Unsupported CPU architecture for automatic jq install: $(uname -m)"
      error "Install jq manually and retry."
      exit 1
      ;;
  esac
}

expected_checksum_from_file() {
  local checksum_file="$1"
  local asset_name="$2"

  awk -v asset="$asset_name" '
    {
      for (i = 1; i <= NF; i += 2) {
        if ($(i + 1) == asset) {
          print $i
          exit
        }
      }
    }
  ' "$checksum_file"
}

install_local_jq_binary() {
  local asset_name
  local download_url
  local tmp_jq
  local tmp_sums
  local expected
  local actual

  asset_name="$(detect_jq_asset_name)"
  download_url="${JQ_RELEASE_BASE}/${asset_name}"
  tmp_jq="$(mktemp "${TMPDIR:-/tmp}/${APP_NAME}.jq.XXXXXX")"
  tmp_sums="$(mktemp "${TMPDIR:-/tmp}/${APP_NAME}.jqsums.XXXXXX")"

  info "jq not found. Downloading official jq ${JQ_VERSION} binary (${asset_name})."
  if ! curl -fsSL "$download_url" -o "$tmp_jq"; then
    rm -f "$tmp_jq" "$tmp_sums"
    error "Could not download jq binary from ${download_url}"
    exit 1
  fi

  if ! curl -fsSL "$JQ_CHECKSUMS_URL" -o "$tmp_sums"; then
    rm -f "$tmp_jq" "$tmp_sums"
    error "Could not download jq checksums from ${JQ_CHECKSUMS_URL}"
    exit 1
  fi

  expected="$(expected_checksum_from_file "$tmp_sums" "$asset_name")"
  if [[ -z "$expected" ]]; then
    rm -f "$tmp_jq" "$tmp_sums"
    error "Could not find checksum for ${asset_name} in ${JQ_CHECKSUMS_URL}"
    exit 1
  fi

  actual="$(shasum -a 256 "$tmp_jq" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    rm -f "$tmp_jq" "$tmp_sums"
    error "Checksum mismatch for downloaded jq binary."
    exit 1
  fi

  mkdir -p "$CLAUDE_BIN_DIR"

  if [[ -e "$LOCAL_JQ_BIN" ]]; then
    if ! cmp -s "$tmp_jq" "$LOCAL_JQ_BIN"; then
      require_confirmation_or_exit "${LOCAL_JQ_BIN} exists and will be replaced. Continue?"
      backup_file "$LOCAL_JQ_BIN"
    else
      info "Local jq binary is already up to date at ${LOCAL_JQ_BIN}."
    fi
  fi

  mv "$tmp_jq" "$LOCAL_JQ_BIN"
  chmod +x "$LOCAL_JQ_BIN"
  rm -f "$tmp_sums"

  info "Installed jq at ${LOCAL_JQ_BIN}"
}

ensure_jq() {
  prepend_local_bin_to_path

  JQ_BIN="$(resolve_jq_in_path)"
  if [[ -n "$JQ_BIN" ]]; then
    return
  fi

  install_local_jq_binary

  prepend_local_bin_to_path
  JQ_BIN="$(resolve_jq_in_path)"
  if [[ -z "$JQ_BIN" ]]; then
    error "jq is still unavailable after local installation."
    exit 1
  fi
}

resolve_source_statusline() {
  if [[ -f "$LOCAL_STATUSLINE" ]]; then
    printf "%s" "$LOCAL_STATUSLINE"
    return
  fi

  local tmpfile
  tmpfile="$(mktemp "${TMPDIR:-/tmp}/${APP_NAME}.statusline.XXXXXX")"

  info "Downloading statusline script from ${REMOTE_STATUSLINE_URL}"
  if ! curl -fsSL "$REMOTE_STATUSLINE_URL" -o "$tmpfile"; then
    rm -f "$tmpfile"
    error "Unable to download statusline.sh from ${REMOTE_STATUSLINE_URL}"
    exit 1
  fi

  printf "%s" "$tmpfile"
}

prepare_statusline_target() {
  local source_script="$1"

  if [[ ! -f "$TARGET_STATUSLINE" ]]; then
    return
  fi

  if cmp -s "$source_script" "$TARGET_STATUSLINE"; then
    info "Existing ${TARGET_STATUSLINE} already matches latest script."
    return
  fi

  require_confirmation_or_exit "${TARGET_STATUSLINE} differs and will be overwritten. Continue?"
  backup_file "$TARGET_STATUSLINE"
}

write_settings_with_statusline() {
  mkdir -p "$CLAUDE_DIR"

  local tmpfile
  local has_statusline
  local current_command
  tmpfile="$(mktemp "${TMPDIR:-/tmp}/${APP_NAME}.settings.XXXXXX")"

  if [[ -f "$SETTINGS_FILE" ]]; then
    if ! "$JQ_BIN" -e 'type == "object"' "$SETTINGS_FILE" >/dev/null 2>&1; then
      rm -f "$tmpfile"
      error "${SETTINGS_FILE} is not a valid JSON object. Fix it manually and retry."
      exit 1
    fi

    has_statusline="$("$JQ_BIN" -r 'has("statusLine")' "$SETTINGS_FILE")"
    if [[ "$has_statusline" == "true" ]]; then
      current_command="$("$JQ_BIN" -r '.statusLine.command // empty' "$SETTINGS_FILE")"
      if [[ -n "$current_command" && "$current_command" != "$STATUSLINE_COMMAND" ]]; then
        require_confirmation_or_exit "Existing statusLine command (${current_command}) will be replaced. Continue?"
      elif [[ -z "$current_command" ]]; then
        require_confirmation_or_exit "Existing statusLine configuration will be replaced. Continue?"
      fi
    fi

    "$JQ_BIN" --arg command "$STATUSLINE_COMMAND" \
      '
      .statusLine = (
        if (.statusLine | type) == "object" then
          .statusLine + {type: "command", command: $command}
        else
          {type: "command", command: $command, padding: 2}
        end
      )
      | if (.statusLine.padding == null) then .statusLine.padding = 2 else . end
      ' "$SETTINGS_FILE" > "$tmpfile"

    if cmp -s "$tmpfile" "$SETTINGS_FILE"; then
      rm -f "$tmpfile"
      info "settings.json already contains a compatible statusLine config."
      return
    fi

    backup_file "$SETTINGS_FILE"
  else
    "$JQ_BIN" -n --arg command "$STATUSLINE_COMMAND" \
      '{statusLine: {type: "command", command: $command, padding: 2}}' > "$tmpfile"
  fi

  mv "$tmpfile" "$SETTINGS_FILE"
  info "Updated ${SETTINGS_FILE}"
}

install_or_update() {
  local mode="$1"
  local action_label
  local source_script

  require_macos
  require_base_tools
  ensure_jq

  source_script="$(resolve_source_statusline)"

  mkdir -p "$CLAUDE_DIR"
  prepare_statusline_target "$source_script"

  cp "$source_script" "$TARGET_STATUSLINE"
  chmod +x "$TARGET_STATUSLINE"

  if [[ "$source_script" != "$LOCAL_STATUSLINE" ]]; then
    rm -f "$source_script"
  fi

  write_settings_with_statusline

  if [[ "$mode" == "update" ]]; then
    action_label="Update"
  else
    action_label="Install"
  fi

  info "${action_label} complete. Statusline ready at ${TARGET_STATUSLINE}"
}

safe_to_remove_target() {
  local current_command="$1"

  if [[ "$current_command" == "$STATUSLINE_COMMAND" ]]; then
    return 0
  fi

  if [[ -f "$LOCAL_STATUSLINE" ]] && cmp -s "$LOCAL_STATUSLINE" "$TARGET_STATUSLINE"; then
    return 0
  fi

  return 1
}

uninstall_statusline() {
  local current_command=""
  local settings_valid=false
  local tmpfile

  require_macos
  require_base_tools

  if [[ -f "$SETTINGS_FILE" ]]; then
    ensure_jq
    if "$JQ_BIN" -e 'type == "object"' "$SETTINGS_FILE" >/dev/null 2>&1; then
      settings_valid=true
      current_command="$("$JQ_BIN" -r '.statusLine.command // empty' "$SETTINGS_FILE")"
    else
      warn "${SETTINGS_FILE} is not a valid JSON object. Settings cleanup will be skipped."
    fi
  fi

  if [[ -f "$TARGET_STATUSLINE" ]]; then
    if ! safe_to_remove_target "$current_command"; then
      require_confirmation_or_exit "${TARGET_STATUSLINE} looks custom and will be removed. Continue?"
      backup_file "$TARGET_STATUSLINE"
    fi
    rm -f "$TARGET_STATUSLINE"
    info "Removed ${TARGET_STATUSLINE}"
  else
    info "No installed script found at ${TARGET_STATUSLINE}"
  fi

  if [[ ! -f "$SETTINGS_FILE" ]]; then
    info "No settings file found. Nothing else to clean."
    return
  fi

  if [[ "$settings_valid" != "true" ]]; then
    return
  fi

  if [[ "$current_command" != "$STATUSLINE_COMMAND" ]]; then
    info "statusLine is custom or absent. Leaving ${SETTINGS_FILE} unchanged."
    return
  fi

  tmpfile="$(mktemp "${TMPDIR:-/tmp}/${APP_NAME}.settings.XXXXXX")"
  "$JQ_BIN" 'del(.statusLine)' "$SETTINGS_FILE" > "$tmpfile"

  if cmp -s "$tmpfile" "$SETTINGS_FILE"; then
    rm -f "$tmpfile"
    info "No statusLine cleanup needed."
    return
  fi

  backup_file "$SETTINGS_FILE"
  mv "$tmpfile" "$SETTINGS_FILE"
  info "Removed managed statusLine from ${SETTINGS_FILE}"
}

parse_args() {
  local arg
  local command_set=false
  COMMAND="install"

  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      install|update|uninstall)
        if [[ "$command_set" == "true" && "$COMMAND" != "$arg" ]]; then
          error "Only one command is allowed."
          usage
          exit 1
        fi
        COMMAND="$arg"
        command_set=true
        ;;
      --yes|-y)
        ASSUME_YES=true
        ;;
      --help|-h|help)
        COMMAND="help"
        ;;
      *)
        error "Unknown argument: ${arg}"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  case "$COMMAND" in
    install)
      install_or_update "install"
      ;;
    update)
      install_or_update "update"
      ;;
    uninstall)
      uninstall_statusline
      ;;
    help)
      usage
      ;;
    *)
      error "Unknown command: ${COMMAND}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
