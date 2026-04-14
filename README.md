# nudge

Keep AI coding agents productive. When Codex, Claude Code, or Gemini CLI finishes a task in tmux and stops to wait for input, nudge automatically sends "continue" to keep them going.

Nudge also supports `bd_epic` sessions: instead of nudging a raw agent pane, it
can supervise a repo-local epic runner that drains a `bd` epic and reports
structured `NUDGE_STATUS` lines back to the daemon.

This makes Nudge more agent-friendly for long-running project work: one layer
keeps the session alive, and another layer knows what “the next real unit of
work” actually is.

## The 100x-simple path

The highest-leverage setup is:

1. put a tiny `nudge.json` contract in the target repo
2. run `~/scripts/nudge-epic.sh doctor /path/to/repo`
3. run `~/scripts/nudge-epic.sh bootstrap <session> /path/to/repo <epic-id> --start`
4. use `~/scripts/nudge-status.sh` for the dashboard and `~/scripts/nudge-attention.sh` when you only want the sessions that need a human

That keeps Nudge simple:

- Nudge owns supervision
- the target repo owns task selection
- the repo contract removes setup guesswork for agents

## Nudge vs a Ralph loop

A Ralph loop is a useful generic pattern: run an agent, let it stop, then
restart it with a fresh prompt or fresh context until the broader objective is
done.

Nudge is solving a different layer of the problem. It is the supervisor for
real tmux-based agent sessions, and in `bd_epic` mode it can supervise a
repo-local runner that already knows how to pick the next ready unit of work.

| Dimension | Ralph loop | Nudge |
|---|---|---|
| Main job | Repeat/restart an autonomy loop | Supervise long-running tmux agent sessions |
| Repo awareness | Usually generic | Generic by default, repo-aware via `bd_epic` |
| tmux visibility | Usually minimal/custom | Built in: dashboard, logs, pause/resume, kick |
| Blocked / human states | Custom per setup | First-class in `bd_epic` mode |
| Best for | Broad “keep going” loops | Operational reliability for real sessions |

Use a Ralph loop when:

- you want a generic repeat-until-done pattern
- the repo does not yet have a deterministic runner
- fresh-context restart behavior matters more than session supervision

Use Nudge when:

- you already run agents in tmux
- you want a daemon, dashboard, logs, and pause/resume controls
- you want explicit runtime states like `running`, `waiting_blocked`, and `waiting_human`
- you want to supervise a repo-local runner instead of blindly replaying `continue`

Use both when:

- you want fresh-context iteration plus operational supervision
- the target repo has a deterministic runner and you still want an outer watchdog

Nudge is not trying to replace the Ralph loop idea. It gives long-running agent
work a real supervisor, and `bd_epic` mode adds tracker-aware orchestration
when the target repo supports it.

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
- **Understands epic runners** — if a pane emits `NUDGE_STATUS`, nudge records the structured runtime state instead of treating it like a generic idle shell

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
- Claude Code plugin at `~/.claude/plugins/nudge` (symlinked, gives you `/nudge`)
- Shared skill at `~/.agents/skills/nudge/SKILL.md` (copied from `commands/nudge.md`)
- Codex skill at `~/.codex/skills/nudge → ../../.agents/skills/nudge` (gives you `$nudge` in the Codex composer)

The Claude plugin is a live symlink; the Codex skill file is a copy because Codex silently ignores symlinked `SKILL.md` files. Re-run `./install.sh` after editing `commands/nudge.md` to refresh the Codex copy.

**Why both `/nudge` and `$nudge`?** Claude Code exposes custom commands via a slash popup; Codex exposes skills via a `$`-mention popup (type `$` then the skill name, pick it, and Codex injects the skill into your prompt). They are two different surface mechanisms for the same underlying command set. Codex does not read `~/.codex/prompts/` for custom slash commands — that is a RepoPrompt convention, not a Codex one.

### Requirements

- **tmux** — sessions must be in tmux
- **jq** — JSON processing (`brew install jq`)
- **macOS** or **Linux** (macOS uses launchd, Linux needs a cron job)

### Linux

On Linux, the install script skips launchd and prints a cron command:

```bash
*/3 * * * * ~/scripts/nudge.sh
```

### Maintainer smoke check

```bash
bash scripts/check-contract-flow.sh
```

This exercises the contract-based `doctor`, `bootstrap`, `start`, runtime
status capture, `status`, `attention`, and auto-restart flow against a
temporary repo.

## For agents

If you point Codex or Claude Code at this repo and ask it to set up Nudge for
long-running Codex project work, the agent should be able to do the whole job
without guessing.

### What the agent should do on the user's machine

1. Install Nudge:

```bash
git clone https://github.com/silverstein/nudge.git
cd nudge
./install.sh
```

2. Verify the local prerequisites:

```bash
tmux -V
jq --version
codex --help
```

3. Register a `bd_epic` session for the target repo:

```bash
~/scripts/nudge-epic.sh doctor /abs/path/to/repo
~/scripts/nudge-epic.sh bootstrap dojo /abs/path/to/repo epic-id --start
~/scripts/nudge-epic.sh status dojo
```

4. Confirm the daemon is tracking the session:

```bash
/nudge
tail -50 ~/.nudge/nudge.log
```

### What the target repo must provide

To make Codex actually keep moving through a long-running project, the target
repo needs a deterministic runner. Nudge is the supervisor, not the project
planner.

The target repo should provide a root `nudge.json` file:

```json
{
  "version": 1,
  "session_modes": {
    "bd_epic": {
      "runner_interface": "codex_epic_v1",
      "runner": "node scripts/codex_epic_runner.mjs",
      "default_agent_bin": "codex",
      "default_agent_args": ["--full-auto"],
      "default_taskmaster": false,
      "status_file_env": "NUDGE_STATUS_FILE",
      "states": [
        "running",
        "waiting_no_ready",
        "waiting_blocked",
        "waiting_human",
        "complete",
        "crashed"
      ],
      "required_commands": ["node", "codex", "bd"],
      "required_files": ["scripts/codex_epic_runner.mjs"]
    }
  }
}
```

The target repo should also provide a runner that implements the
`codex_epic_v1` interface:

- a command that can drain the next ready unit of work
- structured status updates via `NUDGE_STATUS {...}`
- a sidecar status file via `NUDGE_STATUS_FILE`
- explicit pause states such as `running`, `waiting_no_ready`, `waiting_blocked`, `waiting_human`, `complete`, and `crashed`

Example runner launch:

```bash
cd /abs/path/to/repo
NUDGE_STATUS_FILE="$HOME/.nudge/runtime/dojo.json" node scripts/codex_epic_runner.mjs epic-id -- --full-auto
```

That split is intentional:

- Nudge owns tmux supervision, daemon scheduling, restart visibility, and dashboard state
- the target repo owns tracker-aware work selection and per-task Codex prompts

### What the agent should not assume

- Do not assume every repo uses `bd`; `bd_epic` is a pattern, not a universal standard.
- Do not assume pane scraping alone is reliable; wrapped terminal output can corrupt JSON lines.
- Do not assume `continue` is the right control signal for `bd_epic` sessions; prefer the runner status and only use `/nudge kick` as a fallback.
- Do not assume the target repo already has a runner; if it does not, the agent should build or ask for one first.

## Usage

### Add a session to monitor

```bash
# In Claude Code:
/nudge add my-session "Working on the auth refactor"

# Or edit ~/.nudge/sessions.json directly
```

### Add a `bd_epic` session

```bash
~/scripts/nudge-epic.sh doctor /Users/silverbook/Sites/minutes
~/scripts/nudge-epic.sh bootstrap dojo /Users/silverbook/Sites/minutes minutes-ylql.2 --start
```

With Taskmaster as the per-bead engine:

```bash
~/scripts/nudge-epic.sh bootstrap dojo /Users/silverbook/Sites/minutes minutes-ylql.2 --start --taskmaster --agent-arg=--sandbox --agent-arg=danger-full-access --agent-arg=-a --agent-arg=never
```

### Check status

```
/nudge              # Dashboard with all sessions
/nudge log          # Recent activity log
/nudge eval         # AI-powered deep evaluation of all sessions
~/scripts/nudge-status.sh   # Attention first, then session summary
```

### Manage sessions

```
/nudge pause design    # Temporarily stop nudging
/nudge resume design   # Resume nudging
/nudge done design     # Mark as complete
/nudge reset design    # Clear state, restart monitoring
/nudge remove design   # Remove entirely
/nudge kick design     # Immediately send "continue" (skip daemon wait)
~/scripts/nudge-epic.sh status dojo  # Show raw bd_epic config + runtime state
~/scripts/nudge-attention.sh         # Show only sessions that need a human
~/scripts/nudge-status.sh            # Attention section + full session summary
```

`bd_epic` sessions write structured runner state to `~/.nudge/runtime/<session>.json`
via `NUDGE_STATUS_FILE`, so the daemon can track epic progress without relying
only on wrapped tmux pane text.

### Agent-friendly `bd_epic` contract

`bd_epic` mode is meant for repos that already have a deterministic work runner,
not for arbitrary shell sessions.

The target repo should provide:

- a runner command that can drain the next ready unit of work
- structured status updates via `NUDGE_STATUS {...}`
- a sidecar status file via `NUDGE_STATUS_FILE`
- explicit pause reasons like `waiting_no_ready`, `waiting_blocked`, and `waiting_human`

That split is intentional:

- `nudge` owns tmux supervision, daemon scheduling, and dashboard state
- the target repo owns tracker-aware work selection and per-task agent prompts

This keeps `nudge` general-purpose while still making it useful for `bd`-driven
agent workflows.

You can start from [examples/nudge.json](examples/nudge.json)
and copy it into the target repo root as `nudge.json`.

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
