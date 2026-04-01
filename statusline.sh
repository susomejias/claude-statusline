#!/usr/bin/env bash

input=$(cat)
[ -z "$input" ] && printf "Claude" && exit 0

JQ_BIN="$(command -v jq 2>/dev/null || true)"
[ -z "$JQ_BIN" ] && [ -x "$HOME/.claude/bin/jq" ] && JQ_BIN="$HOME/.claude/bin/jq"
[ -z "$JQ_BIN" ] && printf "Claude" && exit 0

# Colors
RESET='\033[0m'
DIM='\033[2m'
GREEN='\033[38;2;0;175;80m'
ORANGE='\033[38;2;255;176;85m'
YELLOW='\033[38;2;230;200;0m'
RED='\033[38;2;255;85;85m'
CYAN='\033[38;2;86;182;194m'
BLUE='\033[38;2;0;153;255m'
WHITE='\033[38;2;220;220;220m'
MAGENTA='\033[38;2;180;140;255m'

SEP=" ${DIM}│${RESET} "

color_pct() {
  local p=$1
  if   (( p >= 90 )); then printf "$RED"
  elif (( p >= 70 )); then printf "$YELLOW"
  elif (( p >= 50 )); then printf "$ORANGE"
  else                     printf "$GREEN"
  fi
}

progress_bar() {
  local pct=$1 width=10
  local remaining=$(( 100 - pct ))
  local filled=$(( remaining * width / 100 ))
  local color; color=$(color_pct "$pct")
  local bar=""
  for (( i=0; i<width; i++ )); do
    (( i < filled )) && bar+="${color}●${RESET}" || bar+="${DIM}○${RESET}"
  done
  printf "%b" "$bar"
}

iso_to_epoch() {
  local iso="${1%%.*}"; iso="${iso%%Z}"
  TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$iso" +%s 2>/dev/null
}

format_time() {
  local epoch; epoch=$(iso_to_epoch "$1")
  [ -z "$epoch" ] && return
  date -j -r "$epoch" +"%H:%M" 2>/dev/null
}

format_datetime() {
  local epoch; epoch=$(iso_to_epoch "$1")
  [ -z "$epoch" ] && return
  date -j -r "$epoch" +"%a %-d %b, %H:%M" 2>/dev/null
}

# Extract native Claude Code data
model=$(echo "$input" | "$JQ_BIN" -r '.model.display_name // "Claude"')
cwd=$(echo "$input" | "$JQ_BIN" -r '.cwd // ""')
size=$(echo "$input" | "$JQ_BIN" -r '.context_window.context_window_size // 200000')
input_tokens=$(echo "$input" | "$JQ_BIN" -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | "$JQ_BIN" -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | "$JQ_BIN" -r '.context_window.current_usage.cache_read_input_tokens // 0')
session_start=$(echo "$input" | "$JQ_BIN" -r '.session.start_time // empty')
lines_added=$(echo "$input" | "$JQ_BIN" -r '.cost.total_lines_added // 0' 2>/dev/null)
lines_removed=$(echo "$input" | "$JQ_BIN" -r '.cost.total_lines_removed // 0' 2>/dev/null)
total_cost=$(echo "$input" | "$JQ_BIN" -r '.cost.total_cost_usd // empty' 2>/dev/null)
output_tokens=$(echo "$input" | "$JQ_BIN" -r '.context_window.total_output_tokens // 0' 2>/dev/null)

current_tokens=$(( input_tokens + cache_create + cache_read ))
(( size == 0 )) && size=200000
ctx_pct=$(( current_tokens * 100 / size ))

# Directory and git
dir_name="${cwd##*/}"
[ -z "$dir_name" ] && dir_name="$cwd"
git_branch=""
git_dirty=""
if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
  [ ${#git_branch} -gt 25 ] && git_branch="${git_branch:0:25}…"
  [ -n "$(git -C "$cwd" status --porcelain --no-optional-locks 2>/dev/null)" ] && git_dirty="*"
fi

# Session duration
duration=""
if [ -n "$session_start" ]; then
  start=$(iso_to_epoch "$session_start")
  if [ -n "$start" ]; then
    elapsed=$(( $(date +%s) - start ))
    if   (( elapsed >= 3600 )); then duration="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"
    elif (( elapsed >= 60   )); then duration="$(( elapsed / 60 ))m"
    else                              duration="${elapsed}s"
    fi
  fi
fi

# Thinking mode
thinking_on=false
settings="$HOME/.claude/settings.json"
[ -f "$settings" ] && [ "$("$JQ_BIN" -r '.alwaysThinkingEnabled // false' "$settings" 2>/dev/null)" = "true" ] && thinking_on=true

# Line 1: Model | Context | Dir (branch) | Duration | Thinking
ctx_remaining=$(( 100 - ctx_pct ))
ctx_color=$(color_pct "$ctx_pct")
line1="${BLUE}${model}${RESET}${SEP}"
line1+="✍️ ${ctx_color}${ctx_remaining}%${RESET}${SEP}"
line1+="${CYAN}${dir_name}${RESET}"
[ -n "$git_branch" ] && line1+=" ${GREEN}(${git_branch}${RED}${git_dirty}${GREEN})${RESET}"
[ -n "$duration" ]   && line1+="${SEP}${WHITE}${duration}${RESET}"
line1+="${SEP}${GREEN}+${lines_added}${RESET}${DIM}/${RESET}${RED}-${lines_removed}${RESET}"

# Get OAuth token from macOS Keychain or credentials file
get_token() {
  local blob; blob=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
  if [ -n "$blob" ]; then
    local t; t=$(echo "$blob" | "$JQ_BIN" -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    [ -n "$t" ] && echo "$t" && return
  fi
  local creds="$HOME/.claude/.credentials.json"
  [ -f "$creds" ] && "$JQ_BIN" -r '.claudeAiOauth.accessToken // empty' "$creds" 2>/dev/null
}

# Fetch usage with 90s cache (1m30s)
CACHE="/tmp/claude-statusline-cache.json"
CACHE_TTL_SECONDS=90
usage=""
if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -f %m "$CACHE") ))
  (( age <= CACHE_TTL_SECONDS )) && usage=$(cat "$CACHE")
fi
if [ -z "$usage" ]; then
  token=$(get_token)
  if [ -n "$token" ]; then
    resp=$(curl -s --max-time 5 \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: claude-code/2.1.34" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    if echo "$resp" | "$JQ_BIN" -e '.five_hour' >/dev/null 2>&1; then
      usage="$resp"; echo "$resp" > "$CACHE"
    fi
  fi
  [ -z "$usage" ] && [ -f "$CACHE" ] && usage=$(cat "$CACHE")
fi

# Lines 2-3: Rate limit bars (subscription) or cost + token info (API billing)
rate_lines=""
if [ -n "$usage" ]; then
  fh_pct=$(echo "$usage" | "$JQ_BIN" -r '.five_hour.utilization // 0' | awk '{printf "%.0f", $1}')
  fh_reset=$(format_time "$(echo "$usage" | "$JQ_BIN" -r '.five_hour.resets_at // empty')")
  fh_color=$(color_pct "$fh_pct")

  wd_pct=$(echo "$usage" | "$JQ_BIN" -r '.seven_day.utilization // 0' | awk '{printf "%.0f", $1}')
  wd_reset=$(format_datetime "$(echo "$usage" | "$JQ_BIN" -r '.seven_day.resets_at // empty')")
  wd_color=$(color_pct "$wd_pct")

  fh_remaining=$(( 100 - fh_pct ))
  wd_remaining=$(( 100 - wd_pct ))

  rate_lines="${WHITE}Current${RESET} $(progress_bar "$fh_pct") ${fh_color}$(printf "%3d" "$fh_remaining")% left${RESET} ${DIM}⟳ ${RESET}${WHITE}${fh_reset}${RESET}"
  rate_lines+="\n${WHITE}Weekly${RESET}  $(progress_bar "$wd_pct") ${wd_color}$(printf "%3d" "$wd_remaining")% left${RESET} ${DIM}⟳ ${RESET}${WHITE}${wd_reset}${RESET}"
elif [ -n "$total_cost" ]; then
  cost_fmt=$(printf "%.4f" "$total_cost")
  in_k=$(awk "BEGIN{printf \"%.1f\", $current_tokens/1000}")
  out_k=$(awk "BEGIN{printf \"%.1f\", $output_tokens/1000}")
  rate_lines="${WHITE}Cost${RESET}    ${GREEN}\$${cost_fmt}${RESET}"
  rate_lines+="\n${WHITE}Tokens${RESET}  ${DIM}in${RESET} ${WHITE}${in_k}k${RESET}${SEP}${DIM}cache write${RESET} ${WHITE}${cache_create}${RESET}${SEP}${DIM}cache read${RESET} ${WHITE}${cache_read}${RESET}${SEP}${DIM}out${RESET} ${WHITE}${out_k}k${RESET}"
fi

printf "%b" "$line1"
[ -n "$rate_lines" ] && printf "\n\n%b" "$rate_lines"
printf "\n"
