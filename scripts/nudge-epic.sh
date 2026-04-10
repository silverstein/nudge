#!/bin/bash
# nudge-epic.sh — configure and launch bd_epic sessions for nudge.

set -euo pipefail

STATE_DIR="$HOME/.nudge"
SESSIONS_FILE="$STATE_DIR/sessions.json"
LOCKDIR="$STATE_DIR/.sessions.lock"

mkdir -p "$STATE_DIR" "$STATE_DIR/snapshots" "$STATE_DIR/runtime"

usage() {
    cat <<'EOF'
Usage:
  nudge-epic.sh add <session> <repo> <epic-id> [--taskmaster] [--tmux-session <name>] [--prompt-file <path>] [--agent-bin <bin>] [--agent-arg <arg> ...]
  nudge-epic.sh start <session>
  nudge-epic.sh status <session>
EOF
}

ensure_config() {
    if [[ ! -f "$SESSIONS_FILE" ]]; then
        cat > "$SESSIONS_FILE" <<'JSONEOF'
{
  "sessions": {},
  "config": {
    "nudgeMessage": "continue",
    "intervalSeconds": 180,
    "cooldownNudges": 20,
    "completionPhrases": [
      "all tasks complete",
      "all beads closed",
      "epic is empty",
      "nothing left to do",
      "no more tasks",
      "everything is done",
      "all items done",
      "finished all",
      "completed all",
      "no remaining work"
    ],
    "blockedPhrases": [
      "I am blocked",
      "I cannot proceed without your",
      "waiting for your input",
      "need your permission",
      "please provide",
      "I need you to"
    ]
  }
}
JSONEOF
    fi
}

json_update_args() {
    local jq_script="$1"
    shift
    local max_wait=5
    local waited=0
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        sleep 0.2
        waited=$(( waited + 1 ))
        if (( waited >= max_wait * 5 )); then
            if [[ -d "$LOCKDIR" ]]; then
                rmdir "$LOCKDIR" 2>/dev/null || true
            fi
            echo "Failed to acquire sessions lock" >&2
            exit 1
        fi
    done
    if jq "$@" "$jq_script" "$SESSIONS_FILE" > "$SESSIONS_FILE.tmp"; then
        mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
    else
        rm -f "$SESSIONS_FILE.tmp"
        rmdir "$LOCKDIR" 2>/dev/null || true
        echo "jq update failed" >&2
        exit 1
    fi
    rmdir "$LOCKDIR" 2>/dev/null || true
}

shell_quote_join() {
    local out=""
    local item
    for item in "$@"; do
        if [[ -n "$out" ]]; then
            out+=" "
        fi
        out+=$(printf '%q' "$item")
    done
    printf '%s' "$out"
}

ensure_config

subcommand="${1:-}"
if [[ -z "$subcommand" ]]; then
    usage
    exit 1
fi
shift || true

case "$subcommand" in
    add)
        session="${1:-}"
        repo="${2:-}"
        epic_id="${3:-}"
        if [[ -z "$session" || -z "$repo" || -z "$epic_id" ]]; then
            usage
            exit 1
        fi
        shift 3

        tmux_session="$session"
        taskmaster=false
        prompt_file=""
        agent_bin="codex"
        agent_args=()

        while [[ $# -gt 0 ]]; do
            case "$1" in
                --taskmaster)
                    taskmaster=true
                    shift
                    ;;
                --tmux-session)
                    tmux_session="${2:-}"
                    shift 2
                    ;;
                --prompt-file)
                    prompt_file="${2:-}"
                    shift 2
                    ;;
                --agent-bin)
                    agent_bin="${2:-}"
                    shift 2
                    ;;
                --agent-arg)
                    agent_args+=("${2:-}")
                    shift 2
                    ;;
                --agent-arg=*)
                    agent_args+=("${1#--agent-arg=}")
                    shift
                    ;;
                *)
                    echo "Unknown option: $1" >&2
                    exit 1
                    ;;
            esac
        done

        taskmaster_json=false
        if $taskmaster; then
            taskmaster_json=true
        fi
        agent_args_json=$(printf '%s\n' "${agent_args[@]}" | jq -R . | jq -s .)

        json_update_args \
            '
            .sessions[$session] = (
              (.sessions[$session] // {})
              + {
                  intent: $intent,
                  active: true,
                  paused: false,
                  nudgeCount: 0,
                  lastNudge: null,
                  completedAt: null,
                  depletedAt: null,
                  mode: "bd_epic",
                  repo: $repo,
                  epicId: $epicId,
                  runner: $runner,
                  agentBin: $agentBin,
                  agentArgs: $agentArgs,
                  taskmaster: $taskmaster,
                  promptFile: (if $promptFile == "" then null else $promptFile end),
                  tmuxSession: $tmuxSession,
                  statusFile: ($statusFile),
                  runtimeState: "waiting_no_ready",
                  currentIssue: null,
                  lastStatusAt: null,
                  lastStatusReason: null,
                  lastExitCode: null
                }
            )
            ' \
            --arg session "$session" \
            --arg intent "Drain bd epic ${epic_id}" \
            --arg repo "$(cd "$repo" && pwd)" \
            --arg epicId "$epic_id" \
            --arg runner "node scripts/codex_epic_runner.mjs" \
            --arg agentBin "$agent_bin" \
            --arg tmuxSession "$tmux_session" \
            --arg statusFile "$STATE_DIR/runtime/${session}.json" \
            --arg promptFile "$prompt_file" \
            --argjson taskmaster "$taskmaster_json" \
            --argjson agentArgs "$agent_args_json" >/dev/null

        echo "Added bd_epic session '$session' for epic $epic_id"
        ;;

    start)
        session="${1:-}"
        if [[ -z "$session" ]]; then
            usage
            exit 1
        fi

        mode=$(jq -r --arg session "$session" '.sessions[$session].mode // empty' "$SESSIONS_FILE")
        if [[ "$mode" != "bd_epic" ]]; then
            echo "Session '$session' is not a bd_epic session" >&2
            exit 1
        fi

        repo=$(jq -r --arg session "$session" '.sessions[$session].repo' "$SESSIONS_FILE")
        epic_id=$(jq -r --arg session "$session" '.sessions[$session].epicId' "$SESSIONS_FILE")
        agent_bin=$(jq -r --arg session "$session" '.sessions[$session].agentBin // "codex"' "$SESSIONS_FILE")
        tmux_session=$(jq -r --arg session "$session" '.sessions[$session].tmuxSession // $session' "$SESSIONS_FILE")
        status_file=$(jq -r --arg session "$session" '.sessions[$session].statusFile // empty' "$SESSIONS_FILE")
        taskmaster=$(jq -r --arg session "$session" '.sessions[$session].taskmaster // false' "$SESSIONS_FILE")
        prompt_file=$(jq -r --arg session "$session" '.sessions[$session].promptFile // empty' "$SESSIONS_FILE")
        agent_args=()
        while IFS= read -r arg; do
            agent_args+=("$arg")
        done < <(jq -r --arg session "$session" '.sessions[$session].agentArgs // [] | .[]' "$SESSIONS_FILE")

        if tmux has-session -t "$tmux_session" 2>/dev/null; then
            echo "tmux session '$tmux_session' already exists" >&2
            exit 1
        fi

        if [[ -n "$status_file" ]]; then
            mkdir -p "$(dirname "$status_file")"
            rm -f "$status_file"
        fi

        runner_cmd=(node scripts/codex_epic_runner.mjs "$epic_id")
        if [[ "$taskmaster" == "true" ]]; then
            runner_cmd+=(--taskmaster)
        elif [[ "$agent_bin" != "codex" ]]; then
            runner_cmd+=(--codex-bin "$agent_bin")
        fi
        if [[ -n "$prompt_file" ]]; then
            runner_cmd+=(--prompt-file "$prompt_file")
        fi
        runner_cmd+=(--)
        runner_cmd+=("${agent_args[@]}")

        launch_cmd="cd $(printf '%q' "$repo") && NUDGE_STATUS_FILE=$(printf '%q' "$status_file") $(shell_quote_join "${runner_cmd[@]}")"
        tmux new-session -d -s "$tmux_session" "$launch_cmd"
        echo "Started tmux session '$tmux_session' for bd_epic '$session'"
        ;;

    status)
        session="${1:-}"
        if [[ -z "$session" ]]; then
            usage
            exit 1
        fi
        jq --arg session "$session" '.sessions[$session]' "$SESSIONS_FILE"
        ;;

    *)
        usage
        exit 1
        ;;
esac
