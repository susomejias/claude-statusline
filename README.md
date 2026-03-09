# claude-statusline

A minimal statusline for [Claude Code](https://claude.ai/code) showing context window, rate limits, git info, and session stats.

```
Claude Sonnet 4.6 │ ✍️ 88% left │ my-project (main) │ ⏱ 42m │ +45/-3 │ ◑ thinking

Current ●●●●●●●○○○  72% left ⟳ 14:30
Weekly  ●●●●●●●●●○  91% left ⟳ Mar 13, 09:00
```

**Line 1** — Model · Context remaining · Directory (git branch) · Session duration · Lines changed · Thinking mode
**Lines 2–3** — Rate limit remaining for the current 5h window and the 7-day rolling window, with reset times in 24h local time

Colors shift green → orange → yellow → red as limits are approached.

## Requirements

- macOS (uses `date -j` and `security` keychain)
- [`jq`](https://jqlang.github.io/jq/) — `brew install jq`
- Claude Code with an active session (OAuth token stored in Keychain)

## Installation

```bash
curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/susomejias/claude-statusline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 2
  }
}
```

The statusline will appear automatically on the next Claude Code interaction.

## How it works

Claude Code pipes a JSON payload to the script on each interaction. The script extracts native fields (model, context window, session start, lines changed) and also fetches rate limit data from the Anthropic API using the OAuth token already stored in your macOS Keychain — no extra credentials needed. Results are cached for 60 seconds to avoid unnecessary requests.

## Credits

Inspired by [kamranahmedse/claude-statusline](https://github.com/kamranahmedse/claude-statusline).
