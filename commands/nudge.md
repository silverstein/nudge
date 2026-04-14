---
name: nudge
description: Manage AI agent fleets (Codex, Claude Code, Gemini) running in tmux. Dashboard over monitored sessions, add/pause/resume/done/reset/kick sessions, eval stalled ones, read logs, tune config. Use when the user says "nudge status", "check my sessions", "is session X done", "pause agent Y", or references the ~/.nudge daemon, sessions.json, or bd_epic runners.
argument-hint: status, add <session> <intent>, done <session>, pause <session>, kick <session>, eval, log, help
---

# Nudge -- Intelligent Agent Fleet Monitor

Manage AI coding agents (Codex, Claude Code, Gemini CLI) running in tmux sessions. Detect stalls, send continuation signals, flag loops.

Nudge also supports a second session type: `bd_epic`. In that mode, Nudge does
not treat the pane like a generic “maybe send continue” target. Instead, it
supervises a repo-local epic runner that drains a `bd` epic and emits
machine-readable `NUDGE_STATUS` lines.

## Architecture

- **Daemon**: `~/scripts/nudge.sh` -- runs every 3 min via launchd
- **Config**: `~/.nudge/sessions.json` -- session registry, intent scratchpad, tuning
- **Snapshots**: `~/.nudge/snapshots/<session>.txt` -- last captured output per session
- **Hashes**: `~/.nudge/<session>.hash` + `<session>.hashcount` -- loop detection state
- **Log**: `~/.nudge/nudge.log` -- audit trail
- **Plist**: `~/Library/LaunchAgents/com.nudge.daemon.plist`

## Agent setup checklist

When an agent is asked to "set up Nudge so Codex can handle long-running
projects," the safe default workflow is:

1. Install Nudge with `./install.sh`
2. Verify `tmux`, `jq`, and `codex` are available
3. Confirm the target repo has a deterministic runner for the next ready work item
4. Validate the target repo with `~/scripts/nudge-epic.sh doctor ...`
5. Register it with `~/scripts/nudge-epic.sh bootstrap ... --start`
6. Verify with `~/scripts/nudge-status.sh`, `~/scripts/nudge-epic.sh status ...`, and `tail -50 ~/.nudge/nudge.log`

Do not skip step 3. Nudge can supervise long-running work, but it does not
invent project-specific work-selection logic on its own.

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
/nudge add-epic <session> <repo> <epic-id> [--taskmaster]  Register a bd_epic session
/nudge bootstrap <session> <repo> <epic-id> [--start]      Read repo contract + create a bd_epic session
/nudge doctor <repo>          Validate a target repo's nudge.json contract
/nudge remove <session>       Stop monitoring, clean up state files
/nudge pause <session>        Temporarily stop nudging (stays in registry)
/nudge resume <session>       Resume a paused session
/nudge done <session>         Mark session as complete
/nudge reset <session>        Clear completed/depleted/nudges, restart monitoring
/nudge intent <session> <txt> Update the goal for a session (keep it to one line)
/nudge start <session>        Start a bd_epic tmux session from saved config
/nudge epic-status <session>  Show saved bd_epic config + last runtime state
/nudge kick <session>         Immediately send "continue" (skip daemon wait)
/nudge attention              Show only sessions that need a human
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
dojo-epic  | bd_epic| running  |     0  |  -   | Drain minutes-ylql.2            | minutes-ylql.2.1
```

6. For any session with state idle/looping/asking or nudge count > 5, do an **intelligent evaluation**:
   - Read the full snapshot + session intent
   - Assess whether the stated intent is actually complete based on agent output
   - If agent summarized full completion -> recommend `/nudge done <session>`
   - If agent finished one task but intent has more -> daemon is correct to keep nudging
   - If looping (hashcount >= 3) -> flag as stuck, suggest manual intervention
   - Report assessment per session

For shell use outside the Claude command surface, the closest equivalent is:

```bash
~/scripts/nudge-status.sh
```

### `/nudge add <session> <intent>`

Add a new tmux session to monitor:

1. Verify tmux session exists: `tmux has-session -t <session>`
2. Add to `~/.nudge/sessions.json` with jq:
   ```json
   { "intent": "<intent>", "active": true, "paused": false, "nudgeCount": 0, "lastNudge": null, "completedAt": null, "depletedAt": null }
   ```
3. Confirm: "Now monitoring `<session>` -- intent: <intent>"

### `/nudge doctor <repo>`

Validate the target repo before you try to bootstrap it:

```bash
~/scripts/nudge-epic.sh doctor <repo>
```

Checks:

- `nudge.json` exists and parses
- contract version is supported
- `session_modes.bd_epic.runner` exists
- required commands are available
- required files exist in the repo

### `/nudge bootstrap <session> <repo> <epic-id> [--start]`

Read the target repo contract and create a `bd_epic` session from it:

```bash
~/scripts/nudge-epic.sh bootstrap <session> <repo> <epic-id> [--start] [--taskmaster]
```

This is the preferred setup path for agents, because it removes hand-built
session config and reuses the target repo's declared runner contract.

### `/nudge add-epic <session> <repo> <epic-id> [--taskmaster]`

Register a `bd_epic` session using the helper script:

```bash
~/scripts/nudge-epic.sh add <session> <repo> <epic-id> [--taskmaster] [--agent-arg=--full-auto]
```

This stores:

- `mode: "bd_epic"`
- `repo`
- `epicId`
- `runner`
- `agentBin`
- `agentArgs`
- `taskmaster`
- runtime fields like `runtimeState`, `currentIssue`, and `lastStatusReason`

Example:

```bash
~/scripts/nudge-epic.sh add dojo /Users/silverbook/Sites/minutes minutes-ylql.2 --agent-arg=--full-auto
```

### `/nudge start <session>`

For `bd_epic` sessions, launch the saved runner into tmux:

```bash
~/scripts/nudge-epic.sh start <session>
```

### `/nudge epic-status <session>`

Show the raw saved config for a `bd_epic` session:

```bash
~/scripts/nudge-epic.sh status <session>
```

### `/nudge attention`

Show only sessions that need a human:

```bash
~/scripts/nudge-attention.sh
```

Right now this highlights:

- `bd_epic` sessions in `waiting_human`, `waiting_blocked`, or `crashed`
- looping sessions
- sessions whose tmux pane disappeared
- sessions that hit nudge cooldown

`bd_epic` sessions also support a light auto-restart policy with backoff. When a
session disappears while its last known runtime state was `running` or
`crashed`, the daemon can relaunch it automatically, increment `restartCount`,
and record the restart timestamps in the session registry.

### `/nudge remove <session>`

Remove a session from monitoring:

1. Remove from sessions.json via jq
2. Clean up: `rm -f ~/.nudge/snapshots/<session>.txt ~/.nudge/<session>.idle ~/.nudge/<session>.hash ~/.nudge/<session>.hashcount`
3. Confirm removal

### `/nudge pause <session>` / `/nudge resume <session>`

Toggle the `paused` flag in sessions.json. Paused sessions stay in the registry but are not nudged. **Resume also resets nudgeCount to 0** and clears hash/hashcount files — otherwise the session immediately hits cooldown from the previous run.

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

**Per-session cooldown override**: Set `cooldownOverride` on any session to override the global `cooldownNudges`. Example: `/nudge config design2 cooldownOverride 100` sets design2 to allow 100 nudges before stopping. Set to `null` to revert to the global default.

### `/nudge kick <session>`

Immediately nudge a session without waiting for the daemon cycle:
```bash
tmux send-keys -t <session> -l "continue"
sleep 0.3
tmux send-keys -t <session> Enter
```

For `bd_epic` sessions, prefer `/nudge start` when no tmux session exists and
prefer `/nudge epic-status` when the runner reports `waiting_blocked`,
`waiting_no_ready`, or `waiting_human`. Use `/nudge kick` only as a fallback
when the runner is visibly sitting at an input prompt.

## `bd_epic` Session Contract

`bd_epic` sessions add these fields under `~/.nudge/sessions.json`:

```json
{
  "mode": "bd_epic",
  "runnerInterface": "codex_epic_v1",
  "repo": "/abs/repo",
  "epicId": "minutes-ylql.2",
  "runner": "node scripts/codex_epic_runner.mjs",
  "agentBin": "codex",
  "agentArgs": ["--full-auto"],
  "taskmaster": false,
  "promptFile": null,
  "tmuxSession": "dojo-epic",
  "statusFile": "/Users/you/.nudge/runtime/dojo-epic.json",
  "runtimeState": "running",
  "currentIssue": "minutes-ylql.2.1",
  "lastStatusAt": "2026-04-10T10:15:00Z",
  "lastStatusReason": null,
  "lastExitCode": null
}
```

The runner is expected to emit lines in this exact form:

```text
NUDGE_STATUS {"state":"running","epic":"minutes-ylql.2","issue":"minutes-ylql.2.1"}
NUDGE_STATUS {"state":"waiting_no_ready","epic":"minutes-ylql.5","reason":"another descendant bead is already in progress"}
NUDGE_STATUS {"state":"waiting_blocked","epic":"minutes-ylql.5","reason":"remaining descendant beads are blocked"}
NUDGE_STATUS {"state":"waiting_human","epic":"minutes-ylql.2","issue":"minutes-ylql.2.3","reason":"child bead returned without closing"}
NUDGE_STATUS {"state":"complete","epic":"minutes-ylql.4"}
NUDGE_STATUS {"state":"crashed","epic":"minutes-ylql.2","exitCode":1,"reason":"codex exec exited non-zero"}
```

When the daemon sees these lines, it records the runtime state and stops
treating the pane like a generic idle shell.

For reliability, `bd_epic` launches should also set `NUDGE_STATUS_FILE` so the
runner writes the latest status JSON to a sidecar file. The daemon reads that
file first and only falls back to pane scraping when the sidecar is missing.

Right now the helper expects `runnerInterface: "codex_epic_v1"`. That means
the target repo's runner must accept this shape:

```bash
<runner> <epic-id> [--taskmaster] [--codex-bin <bin>] [--prompt-file <path>] -- <agent-args...>
```

## Implementation Rules

- Use `tmux capture-pane -t <session> -p -S -N` for captures
- JSON edits use `jq` with `.tmp` + `mv` pattern (atomic writes)
- The daemon uses `mkdir ~/.nudge/.sessions.lock` as a POSIX lock. When editing sessions.json from this command, use the same pattern to prevent races
- When showing status, always capture FRESH tmux output (not stale snapshots)
- Keep intents lean: one line, not paragraphs
- The daemon runs independently -- this command is for management and intelligence, not the nudge loop itself
- If the user's shell aliases `cat` to `bat`, use `/bin/cat` instead
