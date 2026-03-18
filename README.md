# claude-statusline

A minimal statusline for [Claude Code](https://claude.ai/code) showing context window, rate limits, git info, and session stats.

<img width="598" height="72" alt="Captura de pantalla 2026-03-18 a las 23 49 52" src="https://github.com/user-attachments/assets/9de068b9-9fc9-45f0-8905-8c5c6fa9deba" />

**Line 1** — Model · Context remaining · Directory (git branch) · Session duration · Lines changed

**Lines 2–3** — Rate limit remaining for the current 5h window and the 7-day rolling window, with reset times in 24h local time

Colors shift green → orange → yellow → red as limits are approached.

## Requirements

- macOS (uses `date -j` and `security` keychain)
- `bash` and `curl`
- [`jq`](https://jqlang.github.io/jq/) (optional if already installed globally)
- Claude Code with an active session (OAuth token stored in Keychain)

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

The suite covers installer idempotency/safety and `jq` fallback behavior.

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

Claude Code pipes a JSON payload to the script on each interaction. The script extracts native fields (model, context window, session start, lines changed) and also fetches rate limit data from the Anthropic API using the OAuth token already stored in your macOS Keychain — no extra credentials needed. Results are cached for 90 seconds (1 minute 30 seconds) to avoid unnecessary requests.

## Credits

Inspired by [kamranahmedse/claude-statusline](https://github.com/kamranahmedse/claude-statusline).
