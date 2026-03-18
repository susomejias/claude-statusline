#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${ROOT_DIR}/install.sh"
STATUSLINE_SCRIPT="${ROOT_DIR}/statusline.sh"
REAL_JQ="$(command -v jq || true)"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-statusline-tests.XXXXXX")"

cleanup() {
  rm -rf "$TEST_TMP_ROOT"
}
trap cleanup EXIT

pass() {
  printf "PASS %s\n" "$1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  printf "FAIL %s\n" "$1"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

skip() {
  printf "SKIP %s\n" "$1"
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

assert_file_exists() {
  local path="$1"
  [ -f "$path" ] || return 1
}

assert_executable() {
  local path="$1"
  [ -x "$path" ] || return 1
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  [ "$expected" = "$actual" ] || return 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) return 0 ;;
    *) return 1 ;;
  esac
}

assert_glob_exists() {
  local pattern="$1"
  compgen -G "$pattern" >/dev/null 2>&1
}

jq_for_home() {
  local home="$1"

  if [ -x "${home}/.claude/bin/jq" ]; then
    printf "%s\n" "${home}/.claude/bin/jq"
    return 0
  fi

  if [ -n "$REAL_JQ" ]; then
    printf "%s\n" "$REAL_JQ"
    return 0
  fi

  return 1
}

new_home() {
  mktemp -d "${TEST_TMP_ROOT}/home.XXXXXX"
}

test_script_syntax() {
  bash -n "$INSTALL_SCRIPT"
  bash -n "$STATUSLINE_SCRIPT"
}

test_install_creates_files() {
  local home settings jq_bin
  home="$(new_home)"
  settings="${home}/.claude/settings.json"

  HOME="$home" "$INSTALL_SCRIPT" install >/dev/null 2>&1
  jq_bin="$(jq_for_home "$home")"

  assert_executable "${home}/.claude/statusline.sh"
  assert_file_exists "$settings"
  assert_equals "~/.claude/statusline.sh" "$("$jq_bin" -r '.statusLine.command' "$settings")"
  assert_equals "command" "$("$jq_bin" -r '.statusLine.type' "$settings")"
  assert_equals "2" "$("$jq_bin" -r '.statusLine.padding' "$settings")"
}

test_install_conflict_requires_yes() {
  local home settings log
  home="$(new_home)"
  settings="${home}/.claude/settings.json"
  log="${TEST_TMP_ROOT}/install-conflict.log"

  mkdir -p "${home}/.claude"
  cat > "$settings" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "~/custom/statusline.sh",
    "padding": 1
  }
}
JSON

  if HOME="$home" "$INSTALL_SCRIPT" install >"$log" 2>&1; then
    return 1
  fi

  assert_contains "$(cat "$log")" "Run again with --yes"
}

test_install_with_yes_replaces_conflict_and_backups() {
  local home settings jq_bin
  home="$(new_home)"
  settings="${home}/.claude/settings.json"

  mkdir -p "${home}/.claude"
  cat > "$settings" <<'JSON'
{
  "theme": "dark",
  "statusLine": {
    "type": "command",
    "command": "~/custom/statusline.sh",
    "padding": 1
  }
}
JSON

  HOME="$home" "$INSTALL_SCRIPT" install --yes >/dev/null 2>&1
  jq_bin="$(jq_for_home "$home")"

  assert_equals "~/.claude/statusline.sh" "$("$jq_bin" -r '.statusLine.command' "$settings")"
  assert_equals "dark" "$("$jq_bin" -r '.theme' "$settings")"
  assert_glob_exists "${home}/.claude/settings.json.bak.*"
}

test_uninstall_keeps_custom_statusline_setting() {
  local home settings before after
  home="$(new_home)"
  settings="${home}/.claude/settings.json"

  mkdir -p "${home}/.claude"
  cp "$STATUSLINE_SCRIPT" "${home}/.claude/statusline.sh"
  chmod +x "${home}/.claude/statusline.sh"

  cat > "$settings" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "~/custom/status.sh",
    "padding": 9
  },
  "theme": "light"
}
JSON

  before="$(shasum "$settings" | awk '{print $1}')"
  HOME="$home" "$INSTALL_SCRIPT" uninstall >/dev/null 2>&1
  after="$(shasum "$settings" | awk '{print $1}')"

  assert_equals "$before" "$after"
  [ ! -f "${home}/.claude/statusline.sh" ]
}

create_no_jq_path_wrappers() {
  local dir="$1"
  local cmd

  mkdir -p "${dir}/bin"

  cat > "${dir}/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then
  echo Darwin
  exit 0
fi
if [[ "${1:-}" == "-m" ]]; then
  echo x86_64
  exit 0
fi
exec /usr/bin/uname "$@"
EOF
  chmod +x "${dir}/bin/uname"

  for cmd in curl shasum mktemp dirname awk cmp; do
    cat > "${dir}/bin/${cmd}" <<EOF
#!/usr/bin/env bash
exec /usr/bin/${cmd} "\$@"
EOF
    chmod +x "${dir}/bin/${cmd}"
  done
}

test_installs_local_jq_without_homebrew() {
  local home sandbox release checksums asset hash
  [ -n "$REAL_JQ" ] || return 99
  home="$(new_home)"
  sandbox="$(mktemp -d "${TEST_TMP_ROOT}/sandbox.XXXXXX")"
  release="${sandbox}/release"
  checksums="${sandbox}/sha256sum.txt"
  mkdir -p "$release"

  asset="jq-macos-amd64"
  cat > "${release}/${asset}" <<EOF
#!/usr/bin/env bash
exec "${REAL_JQ}" "\$@"
EOF
  chmod +x "${release}/${asset}"
  hash="$(shasum -a 256 "${release}/${asset}" | awk '{print $1}')"
  printf "%s %s\n" "$hash" "$asset" > "$checksums"

  create_no_jq_path_wrappers "$sandbox"

  PATH="${sandbox}/bin:/bin:/usr/sbin:/sbin" \
  HOME="$home" \
  CLAUDE_STATUSLINE_JQ_RELEASE_BASE="file://${release}" \
  CLAUDE_STATUSLINE_JQ_CHECKSUMS_URL="file://${checksums}" \
  "$INSTALL_SCRIPT" install >/dev/null 2>&1

  assert_executable "${home}/.claude/bin/jq"
  assert_equals "2" "$(PATH="${sandbox}/bin:/bin:/usr/sbin:/sbin" "${home}/.claude/bin/jq" -n '1+1')"
}

test_statusline_uses_local_jq_fallback() {
  local home sandbox payload output
  [ -n "$REAL_JQ" ] || return 99
  home="$(new_home)"
  sandbox="$(mktemp -d "${TEST_TMP_ROOT}/statusline-sandbox.XXXXXX")"
  mkdir -p "${home}/.claude/bin" "${sandbox}/bin"

  cat > "${home}/.claude/bin/jq" <<EOF
#!/usr/bin/env bash
exec "${REAL_JQ}" "\$@"
EOF
  chmod +x "${home}/.claude/bin/jq"

  cat > "${sandbox}/bin/git" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "${sandbox}/bin/security" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "${sandbox}/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${sandbox}/bin/git" "${sandbox}/bin/security" "${sandbox}/bin/curl"

  payload='{"model":{"display_name":"Test Model"},"cwd":"/tmp","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"session":{"start_time":"2026-03-18T10:00:00Z"},"cost":{"total_lines_added":1,"total_lines_removed":1}}'
  output="$(printf '%s' "$payload" | PATH="${sandbox}/bin:/bin:/usr/sbin:/sbin" HOME="$home" "$STATUSLINE_SCRIPT")"
  assert_contains "$output" "Test Model"
}

run_test() {
  local test_name="$1"
  local rc

  (set -euo pipefail; "$test_name")
  rc=$?

  case "$rc" in
    0) pass "$test_name" ;;
    99) skip "$test_name" ;;
    *) fail "$test_name" ;;
  esac
}

main() {
  run_test test_script_syntax
  run_test test_install_creates_files
  run_test test_install_conflict_requires_yes
  run_test test_install_with_yes_replaces_conflict_and_backups
  run_test test_uninstall_keeps_custom_statusline_setting
  run_test test_installs_local_jq_without_homebrew
  run_test test_statusline_uses_local_jq_fallback

  printf "\nResult: %d passed, %d failed, %d skipped\n" "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED"
  [ "$TESTS_FAILED" -eq 0 ]
}

main "$@"
