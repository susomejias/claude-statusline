# claude-statusline

A minimal statusline for [Claude Code](https://claude.ai/code) showing context, git info, and session stats.

- Subscription users see current and weekly rate limits.
- API billing / API key users see session cost and token breakdown.

<img width="598" height="72" alt="Captura de pantalla 2026-03-18 a las 23 49 52" src="https://github.com/user-attachments/assets/9de068b9-9fc9-45f0-8905-8c5c6fa9deba" />

<img width="596" height="69" alt="claude-statusline-api-cost" src="https://github.com/user-attachments/assets/4d473b27-2928-4680-80da-95290010aad1" />

**Line 1** — Model · Context remaining · Directory (git branch) · Session duration · Lines changed

**Lines 2–3**

- Subscription: current 5h window and 7-day rolling window, with reset times in local time.
- API billing / API key: session cost in USD plus input, cache write, cache read, and output tokens.

Colors shift green → orange → yellow → red as limits are approached.

## Requirements

- macOS (uses `date -j` and `security` keychain)
- `bash` and `curl`
- [`jq`](https://jqlang.github.io/jq/) (optional if already installed globally)
- Claude Code with an active session

Rate limits require the Claude OAuth token in macOS Keychain. API billing output works from the native Claude Code session payload.

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/susomejias/claude-statusline/main/install.sh | bash
```

The installer will:

- Install `statusline.sh` at `~/.claude/statusline.sh`
- Create/update `~/.claude/settings.json` safely
- Create a timestamped backup before changing existing settings
- If `jq` is missing, download official `jq` binary to `~/.claude/bin/jq` and verify checksum
- Ask for confirmation before any potentially incompatible overwrite

### Update / Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/susomejias/claude-statusline/main/install.sh | bash -s -- update
curl -fsSL https://raw.githubusercontent.com/susomejias/claude-statusline/main/install.sh | bash -s -- uninstall
```

### Safety behavior

- If `statusLine` already points to another command, the installer asks before replacing it.
- If `~/.claude/statusline.sh` differs from the incoming script, the installer asks before overwriting it.
- In non-interactive mode, risky changes require `--yes`.
- `uninstall` only removes `statusLine` when it points to `~/.claude/statusline.sh`.

### Dependency behavior

- If `jq` is already available in `PATH`, it is reused.
- If `jq` is not available, installer places it at `~/.claude/bin/jq`.
- `statusline.sh` automatically falls back to `~/.claude/bin/jq` when global `jq` is not in `PATH`.

### Testing

Run the Bash test suite:

```bash
chmod +x ./tests/test.sh
./tests/test.sh
```

The suite covers installer safety, `jq` fallback behavior, and the API billing cost display.

### Managed Claude setting

The installer manages this block in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 2
  }
}
```

Other settings are preserved.

## How it works

Claude Code pipes a JSON payload to the script on each interaction. The script always reads native fields such as model, context window, session timing, line changes, cost, and tokens.

If the Claude OAuth token is available in macOS Keychain, it also fetches subscription usage from the Anthropic API and shows current and weekly limits. If that usage data is not available, it falls back to the native cost and token data already present in the Claude Code payload. Results from the usage endpoint are cached for 90 seconds.

## Credits

Inspired by [kamranahmedse/claude-statusline](https://github.com/kamranahmedse/claude-statusline).
