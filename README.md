# nudge

Keep AI coding agents productive. When Codex, Claude Code, or Gemini CLI finishes a task in tmux and stops to wait for input, nudge automatically sends "continue" to keep them going.

## The problem

AI coding agents (OpenAI Codex, Claude Code, Gemini CLI) frequently pause after completing a task, waiting for human input before moving on. If you're running multiple agents across tmux sessions on long-running work, you end up babysitting them — checking back every few minutes to type "continue."

## What nudge does

A lightweight daemon watches your tmux sessions every 3 minutes and:

1. **Detects which agent is running** (Codex, Claude Code, Gemini, or generic shell)
2. **Determines the agent's state**: working, idle, asking a question, stuck in a loop, rate-limited, or done
3. **Sends "continue"** only when the agent is genuinely idle and waiting for input
4. **Stays quiet** when the agent is actively working, asking a question, or rate-limited

### Smart, not dumb

Unlike a blind `watch` loop that spams Enter, nudge:

- **Detects agent type** from prompt patterns and working indicators
- **Debounces** — requires 2 consecutive idle checks (~6 min) before nudging
- **Detects loops** — if output is unchanged for 3+ cycles, stops nudging (agent is stuck, not idle)
- **Respects questions** — won't nudge if the agent is asking you something
- **Tracks intent** — knows what each session is supposed to be working on
- **Logs everything** — full audit trail of every decision

## Install

```bash
git clone https://github.com/silverstein/nudge.git
cd nudge
./install.sh
```

This installs:
- `~/scripts/nudge.sh` — the daemon script
- `~/Library/LaunchAgents/com.nudge.daemon.plist` — launchd agent (macOS, runs every 3 min)
- `~/.nudge/` — config, snapshots, and logs
- Claude Code plugin (symlinked, gives you the `/nudge` command)

### Requirements

- **tmux** — sessions must be in tmux
- **jq** — JSON processing (`brew install jq`)
- **macOS** or **Linux** (macOS uses launchd, Linux needs a cron job)

### Linux

On Linux, the install script skips launchd and prints a cron command:

```bash
*/3 * * * * ~/scripts/nudge.sh
```

## Usage

### Add a session to monitor

```bash
# In Claude Code:
/nudge add my-session "Working on the auth refactor"

# Or edit ~/.nudge/sessions.json directly
```

### Check status

```
/nudge              # Dashboard with all sessions
/nudge log          # Recent activity log
/nudge eval         # AI-powered deep evaluation of all sessions
```

### Manage sessions

```
/nudge pause design    # Temporarily stop nudging
/nudge resume design   # Resume nudging
/nudge done design     # Mark as complete
/nudge reset design    # Clear state, restart monitoring
/nudge remove design   # Remove entirely
/nudge kick design     # Immediately send "continue" (skip daemon wait)
```

### Update intent

```
/nudge intent design "Migrating settings pages to new design system"
```

### Full command reference

```
/nudge help
```

## How detection works

### Agent identification

The daemon examines the last 40 lines of each tmux pane and matches against known patterns:

| Agent       | Identified by                                     |
|-------------|----------------------------------------------------|
| Codex       | `Working (`, `Thinking (`, `›` prompt, `gpt-*` status |
| Claude Code | `Cogitated`, `Imagining`, `❯` prompt, `⏵⏵` status bar |
| Gemini CLI  | `Gemini`, `gemini-*` model strings                  |
| Generic     | Falls back to common shell prompts (`$`, `%`, `>`)  |

### State detection

| State       | Meaning                               | Action          |
|-------------|---------------------------------------|-----------------|
| working     | Agent is actively processing          | Skip            |
| idle        | Agent finished, waiting for input     | Nudge (after 2 checks) |
| asking      | Agent is asking a question            | Skip            |
| looping     | Same output for 3+ cycles            | Skip + log      |
| done        | Completion phrases detected           | Mark complete   |
| ratelimited | Rate/usage limit hit                  | Mark stopped    |
| blocked     | Agent says it's blocked               | Skip + log      |

### Loop detection

Every cycle, the daemon hashes the last 20 non-blank lines of each pane. If the hash is identical for 3 consecutive cycles (9+ minutes), the session is marked as `looping` — the agent is stuck, and sending "continue" won't help.

## Configuration

Edit `~/.nudge/sessions.json`:

```json
{
  "sessions": {
    "my-session": {
      "intent": "Working on feature X",
      "active": true,
      "paused": false,
      "nudgeCount": 0,
      "lastNudge": null,
      "completedAt": null,
      "depletedAt": null
    }
  },
  "config": {
    "nudgeMessage": "continue",
    "cooldownNudges": 20,
    "completionPhrases": ["all tasks complete", "nothing left to do"],
    "blockedPhrases": ["I am blocked", "waiting for your input"]
  }
}
```

| Config key | Default | Description |
|------------|---------|-------------|
| `nudgeMessage` | `"continue"` | Text sent to the agent |
| `cooldownNudges` | `20` | Max nudges before stopping (prevents runaway) |
| `completionPhrases` | (see default) | Phrases that trigger auto-complete |
| `blockedPhrases` | (see default) | Phrases that prevent nudging |

## Logs

```bash
# View recent activity
tail -50 ~/.nudge/nudge.log

# Or in Claude Code:
/nudge log 50
```

Log format:
```
2024-03-19 08:32:58 [NUDGE] design2: sent 'continue' (nudge #4, agent=codex)
2024-03-19 08:35:58 [IDLE] design2: marked idle — will nudge on next check if still idle (agent=codex)
2024-03-19 08:38:59 [LOOP] design2: identical output for 3 cycles — not nudging (agent=codex)
```

## Uninstall

```bash
cd nudge
./install.sh --uninstall
```

## License

MIT
