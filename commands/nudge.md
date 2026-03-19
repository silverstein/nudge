# Nudge -- Intelligent Agent Fleet Monitor

Manage AI coding agents (Codex, Claude Code, Gemini CLI) running in tmux sessions. Detect stalls, send continuation signals, flag loops.

## Architecture

- **Daemon**: `~/scripts/nudge.sh` -- runs every 3 min via launchd
- **Config**: `~/.nudge/sessions.json` -- session registry, intent scratchpad, tuning
- **Snapshots**: `~/.nudge/snapshots/<session>.txt` -- last captured output per session
- **Hashes**: `~/.nudge/<session>.hash` + `<session>.hashcount` -- loop detection state
- **Log**: `~/.nudge/nudge.log` -- audit trail
- **Plist**: `~/Library/LaunchAgents/com.nudge.daemon.plist`

## Agent Detection

The daemon auto-detects which agent is running in each session:

| Agent       | Working indicator                            | Idle prompt                                     |
|-------------|----------------------------------------------|-------------------------------------------------|
| Codex       | `Working (`, `Thinking (`                  | `> ` at line start                              |
| Claude Code | `Cogitated`, `Imagining`, spinners           | `>` on own line (between `----` rules)          |
| Gemini CLI  | Spinners, `Generating`, `Thinking`           | `> ` or `>` at line start                       |
| Generic     | --                                           | `$`, `%`, `>`, `>` at EOL                       |

## Loop Detection

The daemon hashes the last 20 non-blank lines of each snapshot. If the hash is identical for 3+ consecutive cycles (9+ minutes), the session is marked `looping` and nudging stops. This prevents wasting agent context on repeated "continue" messages when the agent is stuck.

## Subcommands

Parse `$ARGUMENTS` to determine which subcommand. Default to `status` if no arguments.

### `/nudge help`

Print this quick reference and return:

```
/nudge                        Dashboard: all sessions, state, nudges, context %
/nudge add <session> <intent> Start monitoring a tmux session
/nudge remove <session>       Stop monitoring, clean up state files
/nudge pause <session>        Temporarily stop nudging (stays in registry)
/nudge resume <session>       Resume a paused session
/nudge done <session>         Mark session as complete
/nudge reset <session>        Clear completed/depleted/nudges, restart monitoring
/nudge intent <session> <txt> Update the goal for a session (keep it to one line)
/nudge kick <session>         Immediately send "continue" (skip daemon wait)
/nudge eval                   Deep AI evaluation of all active sessions
/nudge log [N]                Show last N log lines (default 30)
/nudge config <key> <value>   Update daemon config (nudgeMessage, cooldownNudges)
/nudge install                Install/reload the launchd daemon
/nudge uninstall              Stop the launchd daemon
/nudge help                   Show this reference
```

### `/nudge` or `/nudge status`

Show a dashboard of all monitored sessions:

1. Read `~/.nudge/sessions.json`
2. For each session, capture FRESH tmux output: `tmux capture-pane -t <session> -p -S -30`
3. Also read `~/.nudge/<session>.hashcount` for loop detection state
4. Parse context info from agent status lines (Codex: `N% left`, Claude Code: token/cost info)
5. Display a table:

```
Session    | Agent  | State    | Nudges | Loop | Intent                          | Context
-----------|--------|----------|--------|------|---------------------------------|---------
x1         | codex  | working  |     3  |  0   | Biz Entity V2                   | 81% left
design2    | codex  | looping  |     5  |  4   | Styling Tranche                 | 46% left
minutes    | codex  | idle     |     1  |  0   | Global hotkey feature           | 74% left
```

6. For any session with state idle/looping/asking or nudge count > 5, do an **intelligent evaluation**:
   - Read the full snapshot + session intent
   - Assess whether the stated intent is actually complete based on agent output
   - If agent summarized full completion -> recommend `/nudge done <session>`
   - If agent finished one task but intent has more -> daemon is correct to keep nudging
   - If looping (hashcount >= 3) -> flag as stuck, suggest manual intervention
   - Report assessment per session

### `/nudge add <session> <intent>`

Add a new tmux session to monitor:

1. Verify tmux session exists: `tmux has-session -t <session>`
2. Add to `~/.nudge/sessions.json` with jq:
   ```json
   { "intent": "<intent>", "active": true, "paused": false, "nudgeCount": 0, "lastNudge": null, "completedAt": null, "depletedAt": null }
   ```
3. Confirm: "Now monitoring `<session>` -- intent: <intent>"

### `/nudge remove <session>`

Remove a session from monitoring:

1. Remove from sessions.json via jq
2. Clean up: `rm -f ~/.nudge/snapshots/<session>.txt ~/.nudge/<session>.idle ~/.nudge/<session>.hash ~/.nudge/<session>.hashcount`
3. Confirm removal

### `/nudge pause <session>` / `/nudge resume <session>`

Toggle the `paused` flag in sessions.json. Paused sessions stay in the registry but are not nudged.

### `/nudge done <session>`

Mark a session as complete (sets `completedAt` to now). Daemon stops nudging it.

### `/nudge reset <session>`

Reset a session: clear `completedAt`, `depletedAt`, set `nudgeCount` to 0, delete hash/hashcount files. Use when restarting work or unsticking a looping session.

### `/nudge intent <session> <new intent>`

Update the intent for a session. Keep it to one line (current goal/epic/task).

### `/nudge log [N]`

Show the last N lines (default 30) of `~/.nudge/nudge.log`.

### `/nudge eval`

Deep evaluation of ALL active sessions:

1. For each active session, capture fresh tmux output (last 50 lines)
2. Read the intent from sessions.json
3. Read `~/.nudge/<session>.hashcount` for loop state
4. **Think carefully** about each session:
   - Is the stated goal complete? (suggest marking done)
   - Is the agent making progress or spinning? (high nudge count + same hash = stuck)
   - Is the agent looping? (hashcount >= 3 = identical output for 9+ minutes)
   - Should the intent be updated? (agent moved to a different task)
   - Are there errors the agent is stuck on?
5. Report findings with specific recommendations per session

### `/nudge install`

Install/reload the launchd daemon. The plist template is at `${CLAUDE_PLUGIN_ROOT}/scripts/com.nudge.daemon.plist`. Copy it to `~/Library/LaunchAgents/`, substitute `__HOME__` with the user's home directory, then load:
```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.nudge.daemon.plist 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.nudge.daemon.plist
```

### `/nudge uninstall`

Stop and unload the launchd agent:
```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.nudge.daemon.plist
```

### `/nudge config <key> <value>`

Update config values in sessions.json (nudgeMessage, intervalSeconds, cooldownNudges).

### `/nudge kick <session>`

Immediately nudge a session without waiting for the daemon cycle:
```bash
tmux send-keys -t <session> -l "continue"
sleep 0.3
tmux send-keys -t <session> Enter
```

## Implementation Rules

- Use `tmux capture-pane -t <session> -p -S -N` for captures
- JSON edits use `jq` with `.tmp` + `mv` pattern (atomic writes)
- The daemon uses `mkdir ~/.nudge/.sessions.lock` as a POSIX lock. When editing sessions.json from this command, use the same pattern to prevent races
- When showing status, always capture FRESH tmux output (not stale snapshots)
- Keep intents lean: one line, not paragraphs
- The daemon runs independently -- this command is for management and intelligence, not the nudge loop itself
- If the user's shell aliases `cat` to `bat`, use `/bin/cat` instead
