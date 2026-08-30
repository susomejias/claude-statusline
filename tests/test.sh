#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${ROOT_DIR}/install.sh"
STATUSLINE_SCRIPT="${ROOT_DIR}/statusline.sh"
REAL_JQ="$(command -v jq || true)"
STATUSLINE_CACHE_FILE="/tmp/claude-statusline-cache.json"

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

run_statusline_isolated() {
  local backup=""

  if [ -f "$STATUSLINE_CACHE_FILE" ]; then
    backup="$(mktemp "${TEST_TMP_ROOT}/statusline-cache.XXXXXX")"
    mv "$STATUSLINE_CACHE_FILE" "$backup"
  fi

  set +e
  "$@"
  local rc=$?
  set -e

  rm -f "$STATUSLINE_CACHE_FILE"
  if [ -n "$backup" ] && [ -f "$backup" ]; then
    mv "$backup" "$STATUSLINE_CACHE_FILE"
  fi

  return "$rc"
}

create_statusline_command_stubs() {
  local dir="$1"

  mkdir -p "${dir}/bin"

  cat >"${dir}/bin/git" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"${dir}/bin/security" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"${dir}/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"${dir}/bin/awk" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/awk "$@"
EOF
  chmod +x "${dir}/bin/git" "${dir}/bin/security" "${dir}/bin/curl" "${dir}/bin/awk"
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
  assert_equals "true" "$("$jq_bin" -r '.statuslineFableUsage' "$settings")"
}

test_install_conflict_requires_yes() {
  local home settings log
  home="$(new_home)"
  settings="${home}/.claude/settings.json"
  log="${TEST_TMP_ROOT}/install-conflict.log"

  mkdir -p "${home}/.claude"
  cat >"$settings" <<'JSON'
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
  cat >"$settings" <<'JSON'
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

  cat >"$settings" <<'JSON'
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

# Builds a PATH sandbox whose `uname -s` reports the given OS, so the installer's
# OS/asset detection can be exercised for both macOS and Linux from any host.
create_no_jq_path_wrappers() {
  local dir="$1"
  local os_name="${2:-Darwin}"
  local cmd

  mkdir -p "${dir}/bin"

  cat >"${dir}/bin/uname" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-s" ]]; then
  echo ${os_name}
  exit 0
fi
if [[ "\${1:-}" == "-m" ]]; then
  echo x86_64
  exit 0
fi
exec /usr/bin/uname "\$@"
EOF
  chmod +x "${dir}/bin/uname"

  for cmd in curl shasum sha256sum mktemp dirname awk cmp; do
    command -v "$cmd" >/dev/null 2>&1 || continue
    cat >"${dir}/bin/${cmd}" <<EOF
#!/usr/bin/env bash
exec "$(command -v "$cmd")" "\$@"
EOF
    chmod +x "${dir}/bin/${cmd}"
  done
}

# Shared body for the "install downloads a verified jq binary" test, parameterized
# by the simulated OS and its expected release asset name.
assert_installs_local_jq_for_os() {
  local os_name="$1" asset="$2"
  local home sandbox release checksums hash
  [ -n "$REAL_JQ" ] || return 99
  home="$(new_home)"
  sandbox="$(mktemp -d "${TEST_TMP_ROOT}/sandbox.XXXXXX")"
  release="${sandbox}/release"
  checksums="${sandbox}/sha256sum.txt"
  mkdir -p "$release"

  cat >"${release}/${asset}" <<EOF
#!/usr/bin/env bash
exec "${REAL_JQ}" "\$@"
EOF
  chmod +x "${release}/${asset}"
  hash="$(shasum -a 256 "${release}/${asset}" | awk '{print $1}')"
  printf "%s %s\n" "$hash" "$asset" >"$checksums"

  create_no_jq_path_wrappers "$sandbox" "$os_name"

  PATH="${sandbox}/bin:/bin:/usr/sbin:/sbin" \
    HOME="$home" \
    CLAUDE_STATUSLINE_JQ_RELEASE_BASE="file://${release}" \
    CLAUDE_STATUSLINE_JQ_CHECKSUMS_URL="file://${checksums}" \
    "$INSTALL_SCRIPT" install >/dev/null 2>&1

  assert_executable "${home}/.claude/bin/jq"
  assert_equals "2" "$(PATH="${sandbox}/bin:/bin:/usr/sbin:/sbin" "${home}/.claude/bin/jq" -n '1+1')"
}

test_installs_local_jq_without_homebrew() {
  assert_installs_local_jq_for_os "Darwin" "jq-macos-amd64"
}

test_installs_local_jq_on_linux() {
  assert_installs_local_jq_for_os "Linux" "jq-linux-amd64"
}

test_install_via_stdin_works() {
  local home log
  home="$(new_home)"
  log="${TEST_TMP_ROOT}/install-stdin.log"

  cat "$INSTALL_SCRIPT" |
    HOME="$home" \
      CLAUDE_STATUSLINE_SCRIPT_URL="file://${STATUSLINE_SCRIPT}" \
      bash -s -- install >"$log" 2>&1

  assert_executable "${home}/.claude/statusline.sh"
  assert_file_exists "${home}/.claude/settings.json"
  assert_equals "~/.claude/statusline.sh" "$("$(jq_for_home "$home")" -r '.statusLine.command' "${home}/.claude/settings.json")"
}

test_statusline_uses_local_jq_fallback() {
  local home sandbox payload output
  [ -n "$REAL_JQ" ] || return 99
  home="$(new_home)"
  sandbox="$(mktemp -d "${TEST_TMP_ROOT}/statusline-sandbox.XXXXXX")"
  mkdir -p "${home}/.claude/bin"

  cat >"${home}/.claude/bin/jq" <<EOF
#!/usr/bin/env bash
exec "${REAL_JQ}" "\$@"
EOF
  chmod +x "${home}/.claude/bin/jq"

  create_statusline_command_stubs "$sandbox"

  payload='{"model":{"display_name":"Test Model"},"cwd":"/tmp","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"session":{"start_time":"2026-03-18T10:00:00Z"},"cost":{"total_lines_added":1,"total_lines_removed":1}}'
  output="$(printf '%s' "$payload" | run_statusline_isolated env PATH="${sandbox}/bin:/bin:/usr/sbin:/sbin" HOME="$home" "$STATUSLINE_SCRIPT")"
  assert_contains "$output" "Test Model"
}

test_statusline_shows_cost_for_api_billing_users() {
  local home sandbox payload output
  [ -n "$REAL_JQ" ] || return 99
  home="$(new_home)"
  sandbox="$(mktemp -d "${TEST_TMP_ROOT}/statusline-api-billing.XXXXXX")"
  mkdir -p "${home}/.claude/bin"

  cat >"${home}/.claude/bin/jq" <<EOF
#!/usr/bin/env bash
exec "${REAL_JQ}" "\$@"
EOF
  chmod +x "${home}/.claude/bin/jq"

  create_statusline_command_stubs "$sandbox"

  payload='{"model":{"display_name":"Test Model"},"cwd":"/tmp","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":250,"cache_read_input_tokens":250},"total_output_tokens":2500},"session":{"start_time":"2026-03-18T10:00:00Z"},"cost":{"total_lines_added":1,"total_lines_removed":1,"total_cost_usd":1.2345}}'
  output="$(printf '%s' "$payload" | run_statusline_isolated env PATH="${sandbox}/bin:/bin:/usr/sbin:/sbin" HOME="$home" "$STATUSLINE_SCRIPT")"

  assert_contains "$output" "Cost"
  assert_contains "$output" '$1.2345'
  assert_contains "$output" "Tokens"
  assert_contains "$output" "cache write"
  assert_contains "$output" "cache read"
  assert_contains "$output" "2.5k"
}

# An explicit "statuslineFableUsage": false is user intent and must survive
# reinstall; uninstall cleans the managed key up.
test_install_preserves_explicit_fable_toggle() {
  local home settings jq_bin
  home="$(new_home)"
  settings="${home}/.claude/settings.json"

  mkdir -p "${home}/.claude"
  cat >"$settings" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 2
  },
  "statuslineFableUsage": false
}
JSON

  HOME="$home" "$INSTALL_SCRIPT" install >/dev/null 2>&1
  jq_bin="$(jq_for_home "$home")"
  assert_equals "false" "$("$jq_bin" -r '.statuslineFableUsage' "$settings")"

  HOME="$home" "$INSTALL_SCRIPT" uninstall >/dev/null 2>&1
  assert_equals "null" "$("$jq_bin" -r '.statuslineFableUsage' "$settings")"
}

# Sources statusline.sh's pure helpers (without running the renderer) and checks that
# date/stat conversions produce identical results on macOS (BSD) and Linux (GNU).
test_date_helpers_portable() {
  # shellcheck disable=SC1090
  STATUSLINE_SOURCE=1 . "$STATUSLINE_SCRIPT"

  # UTC epoch is timezone-independent, so this is the same on every host.
  assert_equals "1773828000" "$(iso_to_epoch '2026-03-18T10:00:00Z')" || return 1
  # Fractional seconds must be tolerated and stripped.
  assert_equals "1773828000" "$(iso_to_epoch '2026-03-18T10:00:00.123Z')" || return 1
  # Empty input must yield nothing: GNU `date -d "Z"` would invent today's date.
  assert_equals "" "$(iso_to_epoch '')" || return 1
  assert_equals "" "$(format_time '')" || return 1
  assert_equals "" "$(format_datetime '')" || return 1

  # Formatting is local-time; pin TZ so the expected output is deterministic.
  assert_equals "10:00" "$(TZ=UTC format_time '2026-03-18T10:00:00Z')" || return 1
  assert_equals "Wed 18 Mar, 10:00" "$(TZ=UTC format_datetime '2026-03-18T10:00:00Z')" || return 1

  # file_mtime returns a positive integer epoch for an existing file.
  local mtime
  mtime="$(file_mtime "$STATUSLINE_SCRIPT")"
  case "$mtime" in
  '' | *[!0-9]*) return 1 ;;
  esac
}

# The renderer must fall back to the plaintext credentials file when the macOS
# `security` keychain tool is absent (the normal case on Linux).
test_statusline_reads_credentials_file_without_keychain() {
  local home sandbox payload output
  [ -n "$REAL_JQ" ] || return 99
  home="$(new_home)"
  sandbox="$(mktemp -d "${TEST_TMP_ROOT}/statusline-creds.XXXXXX")"
  mkdir -p "${home}/.claude/bin"

  cat >"${home}/.claude/bin/jq" <<EOF
#!/usr/bin/env bash
exec "${REAL_JQ}" "\$@"
EOF
  chmod +x "${home}/.claude/bin/jq"

  # Linux stores the OAuth token here in plaintext with this exact shape.
  cat >"${home}/.claude/.credentials.json" <<'JSON'
{"claudeAiOauth":{"accessToken":"test-token","refreshToken":"r","expiresAt":0,"scopes":[],"subscriptionType":"pro"}}
JSON

  # Sandbox without `security`, and with curl failing so no network is hit.
  mkdir -p "${sandbox}/bin"
  cat >"${sandbox}/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"${sandbox}/bin/git" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${sandbox}/bin/curl" "${sandbox}/bin/git"

  payload='{"model":{"display_name":"Test Model"},"cwd":"/tmp","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"session":{"start_time":"2026-03-18T10:00:00Z"},"cost":{"total_lines_added":1,"total_lines_removed":1}}'
  # No `security` on PATH here — must not error, must still render line 1.
  output="$(printf '%s' "$payload" | run_statusline_isolated env PATH="${sandbox}/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$home" "$STATUSLINE_SCRIPT")"
  assert_contains "$output" "Test Model"
}

# Prepares a home whose statusline can complete an OAuth usage fetch: a plaintext
# credentials file for the token and a curl stub that serves the given usage JSON.
setup_fable_sandbox() {
  local home="$1" sandbox="$2" usage_json="$3"

  mkdir -p "${home}/.claude/bin"
  cat >"${home}/.claude/bin/jq" <<EOF
#!/usr/bin/env bash
exec "${REAL_JQ}" "\$@"
EOF
  chmod +x "${home}/.claude/bin/jq"

  cat >"${home}/.claude/.credentials.json" <<'JSON'
{"claudeAiOauth":{"accessToken":"test-token","refreshToken":"r","expiresAt":0,"scopes":[],"subscriptionType":"pro"}}
JSON

  mkdir -p "${sandbox}/bin"
  cat >"${sandbox}/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s' '${usage_json}'
EOF
  cat >"${sandbox}/bin/git" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${sandbox}/bin/curl" "${sandbox}/bin/git"
}

# While a Fable model is active, the usage endpoint's Fable-specific pool (key
# shape not publicly documented — matched tolerantly by name) must render as a
# third rate-limit row in the Current/Weekly style.
test_statusline_shows_fable_row_when_fable_model_active() {
  local home sandbox payload output
  [ -n "$REAL_JQ" ] || return 99
  home="$(new_home)"
  sandbox="$(mktemp -d "${TEST_TMP_ROOT}/statusline-fable.XXXXXX")"

  setup_fable_sandbox "$home" "$sandbox" \
    '{"five_hour":{"utilization":40,"resets_at":"2026-03-18T14:00:00Z"},"seven_day":{"utilization":20,"resets_at":"2026-03-20T14:00:00Z"},"limits":[{"kind":"session","group":"session","percent":0,"severity":"normal","resets_at":"2026-03-18T14:00:00Z","scope":null,"is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":90,"severity":"normal","resets_at":null,"scope":{"model":{"id":null,"display_name":"Opus"},"surface":null},"is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":70,"severity":"normal","resets_at":"2026-03-18T15:00:00Z","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}'

  payload='{"model":{"id":"claude-fable-5","display_name":"Test Model"},"cwd":"/tmp","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"session":{"start_time":"2026-03-18T10:00:00Z"},"cost":{"total_lines_added":1,"total_lines_removed":1}}'
  output="$(printf '%s' "$payload" | run_statusline_isolated env PATH="${sandbox}/bin:/bin:/usr/sbin:/sbin" TZ=UTC HOME="$home" "$STATUSLINE_SCRIPT")"

  assert_contains "$output" "Fable"
  assert_contains "$output" "30% left"
  # The reset must render weekly-style (full datetime), not 5h-style HH:MM.
  assert_contains "$output" "18 Mar"
}

# The Fable row is opt-out via ~/.claude/settings.json and must never render for
# other models, even when the usage payload carries a Fable pool.
test_statusline_fable_row_toggle_and_model_guard() {
  local home sandbox payload output
  [ -n "$REAL_JQ" ] || return 99
  home="$(new_home)"
  sandbox="$(mktemp -d "${TEST_TMP_ROOT}/statusline-fable-toggle.XXXXXX")"

  setup_fable_sandbox "$home" "$sandbox" \
    '{"five_hour":{"utilization":40,"resets_at":"2026-03-18T14:00:00Z"},"seven_day":{"utilization":20,"resets_at":"2026-03-20T14:00:00Z"},"limits":[{"kind":"session","group":"session","percent":0,"severity":"normal","resets_at":"2026-03-18T14:00:00Z","scope":null,"is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":90,"severity":"normal","resets_at":null,"scope":{"model":{"id":null,"display_name":"Opus"},"surface":null},"is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":70,"severity":"normal","resets_at":"2026-03-18T15:00:00Z","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}'

  # Non-Fable model: no Fable row even though the pool is present.
  payload='{"model":{"id":"claude-sonnet-4-5","display_name":"Test Model"},"cwd":"/tmp","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"session":{"start_time":"2026-03-18T10:00:00Z"},"cost":{"total_lines_added":1,"total_lines_removed":1}}'
  output="$(printf '%s' "$payload" | run_statusline_isolated env PATH="${sandbox}/bin:/bin:/usr/sbin:/sbin" HOME="$home" "$STATUSLINE_SCRIPT")"
  case "$output" in
  *"Fable"*) return 1 ;;
  esac

  # Fable model with the toggle disabled: no Fable row.
  printf '%s' '{"statuslineFableUsage": false}' >"${home}/.claude/settings.json"
  payload='{"model":{"id":"claude-fable-5","display_name":"Test Model"},"cwd":"/tmp","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"session":{"start_time":"2026-03-18T10:00:00Z"},"cost":{"total_lines_added":1,"total_lines_removed":1}}'
  output="$(printf '%s' "$payload" | run_statusline_isolated env PATH="${sandbox}/bin:/bin:/usr/sbin:/sbin" HOME="$home" "$STATUSLINE_SCRIPT")"
  case "$output" in
  *"Fable"*) return 1 ;;
  esac
}

# An unused Fable limit carries resets_at null; the row must render without a
# reset time (the dashboard shows "You haven't used Fable yet"), and only the
# Current/Weekly rows may carry the ⟳ marker.
test_statusline_fable_row_hides_null_reset() {
  local home sandbox payload output resets
  [ -n "$REAL_JQ" ] || return 99
  home="$(new_home)"
  sandbox="$(mktemp -d "${TEST_TMP_ROOT}/statusline-fable-null-reset.XXXXXX")"

  setup_fable_sandbox "$home" "$sandbox" \
    '{"five_hour":{"utilization":40,"resets_at":"2026-03-18T14:00:00Z"},"seven_day":{"utilization":20,"resets_at":"2026-03-20T14:00:00Z"},"limits":[{"kind":"weekly_scoped","group":"weekly","percent":70,"severity":"normal","resets_at":null,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}'

  payload='{"model":{"id":"claude-fable-5","display_name":"Test Model"},"cwd":"/tmp","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"session":{"start_time":"2026-03-18T10:00:00Z"},"cost":{"total_lines_added":1,"total_lines_removed":1}}'
  output="$(printf '%s' "$payload" | run_statusline_isolated env PATH="${sandbox}/bin:/bin:/usr/sbin:/sbin" HOME="$home" "$STATUSLINE_SCRIPT")"

  assert_contains "$output" "Fable"
  resets="$(printf '%s' "$output" | grep -o '⟳' | wc -l | tr -d ' ')"
  assert_equals "2" "$resets"
}

run_test() {
  local test_name="$1"
  local rc

  (
    set -euo pipefail
    "$test_name"
  )
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
  run_test test_install_preserves_explicit_fable_toggle
  run_test test_installs_local_jq_without_homebrew
  run_test test_installs_local_jq_on_linux
  run_test test_install_via_stdin_works
  run_test test_statusline_uses_local_jq_fallback
  run_test test_statusline_shows_cost_for_api_billing_users
  run_test test_date_helpers_portable
  run_test test_statusline_reads_credentials_file_without_keychain
  run_test test_statusline_shows_fable_row_when_fable_model_active
  run_test test_statusline_fable_row_toggle_and_model_guard
  run_test test_statusline_fable_row_hides_null_reset

  printf "\nResult: %d passed, %d failed, %d skipped\n" "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED"
  [ "$TESTS_FAILED" -eq 0 ]
}

main "$@"
