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
  nudge-epic.sh bootstrap <session> <repo> <epic-id> [--start] [--taskmaster] [--tmux-session <name>] [--prompt-file <path>] [--agent-bin <bin>] [--agent-arg <arg> ...]
  nudge-epic.sh doctor <repo>
  nudge-epic.sh start <session>
  nudge-epic.sh status <session>
  nudge-epic.sh attention
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

read_file() {
    /bin/cat "$1" 2>/dev/null || cat "$1" 2>/dev/null || true
}

contract_file_for_repo() {
    local repo="$1"
    if [[ -f "$repo/nudge.json" ]]; then
        printf '%s\n' "$repo/nudge.json"
        return 0
    fi
    return 1
}

doctor_repo() {
    local repo="$1"
    local failures=0
    local contract_file=""

    repo="$(cd "$repo" 2>/dev/null && pwd)" || {
        echo "FAIL repo: could not resolve repo path '$repo'"
        return 1
    }

    echo "Doctor: $repo"

    if ! contract_file=$(contract_file_for_repo "$repo"); then
        echo "FAIL contract: missing $repo/nudge.json"
        failures=$(( failures + 1 ))
    else
        echo "OK   contract: $contract_file"
    fi

    if [[ -n "$contract_file" ]]; then
        if jq -e . "$contract_file" >/dev/null 2>&1; then
            echo "OK   contract-json: valid JSON"
        else
            echo "FAIL contract-json: invalid JSON"
            failures=$(( failures + 1 ))
        fi

        local version
        version=$(jq -r '.version // empty' "$contract_file")
        if [[ "$version" == "1" ]]; then
            echo "OK   version: 1"
        else
            echo "FAIL version: expected 1, got '${version:-missing}'"
            failures=$(( failures + 1 ))
        fi

        local runner
        runner=$(jq -r '.session_modes.bd_epic.runner // empty' "$contract_file")
        if [[ -n "$runner" ]]; then
            echo "OK   runner: $runner"
        else
            echo "FAIL runner: .session_modes.bd_epic.runner missing"
            failures=$(( failures + 1 ))
        fi

        local runner_interface
        runner_interface=$(jq -r '.session_modes.bd_epic.runner_interface // empty' "$contract_file")
        if [[ "$runner_interface" == "codex_epic_v1" ]]; then
            echo "OK   runner-interface: $runner_interface"
        else
            echo "FAIL runner-interface: expected codex_epic_v1, got '${runner_interface:-missing}'"
            failures=$(( failures + 1 ))
        fi

        local status_env
        status_env=$(jq -r '.session_modes.bd_epic.status_file_env // "NUDGE_STATUS_FILE"' "$contract_file")
        if [[ "$status_env" == "NUDGE_STATUS_FILE" ]]; then
            echo "OK   status-env: $status_env"
        else
            echo "FAIL status-env: expected NUDGE_STATUS_FILE-compatible contract, got '$status_env'"
            failures=$(( failures + 1 ))
        fi

        local state_count
        state_count=$(jq -r '.session_modes.bd_epic.states // [] | length' "$contract_file")
        if [[ "$state_count" -ge 4 ]]; then
            echo "OK   states: $state_count declared"
        else
            echo "FAIL states: expected at least 4 declared runtime states"
            failures=$(( failures + 1 ))
        fi

        while IFS= read -r cmd; do
            [[ -z "$cmd" ]] && continue
            if command -v "$cmd" >/dev/null 2>&1; then
                echo "OK   command:$cmd"
            else
                echo "FAIL command:$cmd not found on PATH"
                failures=$(( failures + 1 ))
            fi
        done < <(jq -r '.session_modes.bd_epic.required_commands // [] | .[]' "$contract_file")

        local default_agent_bin
        default_agent_bin=$(jq -r '.session_modes.bd_epic.default_agent_bin // empty' "$contract_file")
        if [[ -n "$default_agent_bin" ]]; then
            if command -v "$default_agent_bin" >/dev/null 2>&1; then
                echo "OK   default-agent:$default_agent_bin"
            else
                echo "FAIL default-agent:$default_agent_bin not found on PATH"
                failures=$(( failures + 1 ))
            fi
        fi

        while IFS= read -r relpath; do
            [[ -z "$relpath" ]] && continue
            if [[ -e "$repo/$relpath" ]]; then
                echo "OK   file:$relpath"
            else
                echo "FAIL file:$relpath missing"
                failures=$(( failures + 1 ))
            fi
        done < <(jq -r '.session_modes.bd_epic.required_files // [] | .[]' "$contract_file")
    fi

    if [[ "$failures" -gt 0 ]]; then
        echo "Doctor result: FAIL ($failures issue(s))"
        return 1
    fi

    echo "Doctor result: OK"
    return 0
}

merge_agent_args_json() {
    local default_json="$1"
    shift
    local extras=("$@")
    if [[ ${#extras[@]} -eq 0 ]]; then
        printf '%s' "$default_json"
        return 0
    fi
    local extras_json
    extras_json=$(printf '%s\n' "${extras[@]}" | jq -R . | jq -s .)
    jq -cn --argjson defaults "$default_json" --argjson extras "$extras_json" '$defaults + $extras'
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
                  contractFile: null,
                  runnerInterface: "codex_epic_v1",
                  repo: $repo,
                  epicId: $epicId,
                  runner: $runner,
                  agentBin: $agentBin,
                  agentArgs: $agentArgs,
                  taskmaster: $taskmaster,
                  promptFile: (if $promptFile == "" then null else $promptFile end),
                  tmuxSession: $tmuxSession,
                  statusFile: ($statusFile),
                  autoRestart: true,
                  restartCount: 0,
                  maxAutoRestarts: 3,
                  restartCooldownSeconds: 300,
                  lastRestartAt: null,
                  lastRestartEpoch: null,
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

    bootstrap)
        session="${1:-}"
        repo="${2:-}"
        epic_id="${3:-}"
        if [[ -z "$session" || -z "$repo" || -z "$epic_id" ]]; then
            usage
            exit 1
        fi
        shift 3

        start_after=false
        tmux_session="$session"
        taskmaster=""
        prompt_file=""
        agent_bin=""
        extra_agent_args=()

        while [[ $# -gt 0 ]]; do
            case "$1" in
                --start)
                    start_after=true
                    shift
                    ;;
                --taskmaster)
                    taskmaster="true"
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
                    extra_agent_args+=("${2:-}")
                    shift 2
                    ;;
                --agent-arg=*)
                    extra_agent_args+=("${1#--agent-arg=}")
                    shift
                    ;;
                *)
                    echo "Unknown option: $1" >&2
                    exit 1
                    ;;
            esac
        done

        repo="$(cd "$repo" && pwd)"
        contract_file=$(contract_file_for_repo "$repo") || {
            echo "Missing $repo/nudge.json" >&2
            exit 1
        }

        doctor_repo "$repo"

        runner=$(jq -r '.session_modes.bd_epic.runner' "$contract_file")
        runner_interface=$(jq -r '.session_modes.bd_epic.runner_interface' "$contract_file")
        default_agent_args_json=$(jq -c '.session_modes.bd_epic.default_agent_args // []' "$contract_file")
        merged_agent_args_json=$(merge_agent_args_json "$default_agent_args_json" "${extra_agent_args[@]}")

        if [[ -z "$agent_bin" ]]; then
            agent_bin=$(jq -r '.session_modes.bd_epic.default_agent_bin // "codex"' "$contract_file")
        fi
        if [[ -z "$taskmaster" ]]; then
            taskmaster=$(jq -r '.session_modes.bd_epic.default_taskmaster // false' "$contract_file")
        fi

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
                  contractFile: $contractFile,
                  runnerInterface: $runnerInterface,
                  repo: $repo,
                  epicId: $epicId,
                  runner: $runner,
                  agentBin: $agentBin,
                  agentArgs: $agentArgs,
                  taskmaster: $taskmaster,
                  promptFile: (if $promptFile == "" then null else $promptFile end),
                  tmuxSession: $tmuxSession,
                  statusFile: $statusFile,
                  autoRestart: true,
                  restartCount: 0,
                  maxAutoRestarts: 3,
                  restartCooldownSeconds: 300,
                  lastRestartAt: null,
                  lastRestartEpoch: null,
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
            --arg contractFile "$contract_file" \
            --arg runnerInterface "$runner_interface" \
            --arg repo "$repo" \
            --arg epicId "$epic_id" \
            --arg runner "$runner" \
            --arg agentBin "$agent_bin" \
            --arg tmuxSession "$tmux_session" \
            --arg statusFile "$STATE_DIR/runtime/${session}.json" \
            --arg promptFile "$prompt_file" \
            --argjson taskmaster "$taskmaster" \
            --argjson agentArgs "$merged_agent_args_json" >/dev/null

        echo "Bootstrapped bd_epic session '$session' from $contract_file"
        if $start_after; then
            bash "$0" start "$session"
        fi
        ;;

    doctor)
        repo="${1:-}"
        if [[ -z "$repo" ]]; then
            usage
            exit 1
        fi
        doctor_repo "$repo"
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
        runner_interface=$(jq -r --arg session "$session" '.sessions[$session].runnerInterface // "codex_epic_v1"' "$SESSIONS_FILE")
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

        if [[ "$taskmaster" == "true" ]]; then
            command -v codex-taskmaster >/dev/null 2>&1 || {
                echo "codex-taskmaster not found on PATH" >&2
                exit 1
            }
        else
            command -v "$agent_bin" >/dev/null 2>&1 || {
                echo "$agent_bin not found on PATH" >&2
                exit 1
            }
        fi

        if [[ -n "$status_file" ]]; then
            mkdir -p "$(dirname "$status_file")"
            rm -f "$status_file"
        fi

        if [[ "$runner_interface" != "codex_epic_v1" ]]; then
            echo "Unsupported runner interface '$runner_interface' for session '$session'" >&2
            exit 1
        fi

        runner=$(jq -r --arg session "$session" '.sessions[$session].runner // "node scripts/codex_epic_runner.mjs"' "$SESSIONS_FILE")
        runner_cmd="$runner $(printf '%q' "$epic_id")"
        if [[ "$taskmaster" == "true" ]]; then
            runner_cmd+=" --taskmaster"
        elif [[ "$agent_bin" != "codex" ]]; then
            runner_cmd+=" --codex-bin $(printf '%q' "$agent_bin")"
        fi
        if [[ -n "$prompt_file" ]]; then
            runner_cmd+=" --prompt-file $(printf '%q' "$prompt_file")"
        fi
        runner_cmd+=" --"
        if [[ ${#agent_args[@]} -gt 0 ]]; then
            runner_cmd+=" $(shell_quote_join "${agent_args[@]}")"
        fi

        launch_cmd="cd $(printf '%q' "$repo") && NUDGE_STATUS_FILE=$(printf '%q' "$status_file") $runner_cmd"
        tmux new-session -d -s "$tmux_session" "$launch_cmd"
        now_epoch=$(date +%s)
        now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        json_update_args \
            '
            .sessions[$session].runtimeState = "running"
            | .sessions[$session].currentIssue = null
            | .sessions[$session].lastStatusAt = $nowIso
            | .sessions[$session].lastStatusReason = "tmux session launched"
            | .sessions[$session].lastExitCode = null
            ' \
            --arg session "$session" \
            --arg nowIso "$now_iso" >/dev/null
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

    attention)
        if [[ ! -f "$SESSIONS_FILE" ]]; then
            echo "No config yet."
            exit 0
        fi
        found=0
        printed_header=0
        while IFS= read -r session; do
            mode=$(jq -r ".sessions[\"$session\"].mode // \"generic\"" "$SESSIONS_FILE")
            runtime_state=$(jq -r ".sessions[\"$session\"].runtimeState // \"\"" "$SESSIONS_FILE")
            completed=$(jq -r ".sessions[\"$session\"].completedAt // \"null\"" "$SESSIONS_FILE")
            depleted=$(jq -r ".sessions[\"$session\"].depletedAt // \"null\"" "$SESSIONS_FILE")
            paused=$(jq -r ".sessions[\"$session\"].paused // false" "$SESSIONS_FILE")
            nudge_count=$(jq -r ".sessions[\"$session\"].nudgeCount // 0" "$SESSIONS_FILE")
            [[ "$paused" == "true" ]] && continue
            [[ "$completed" != "null" ]] && continue
            [[ "$depleted" != "null" ]] && continue

            reason=""
            if [[ "$mode" == "bd_epic" ]]; then
                case "$runtime_state" in
                    waiting_human|waiting_blocked|crashed)
                        reason="$runtime_state"
                        ;;
                esac
            fi

            hashcount_file="$STATE_DIR/${session}.hashcount"
            if [[ -z "$reason" && -f "$hashcount_file" ]]; then
                hashcount=$(read_file "$hashcount_file")
                if [[ "${hashcount:-0}" -ge 3 ]]; then
                    reason="looping"
                fi
            fi

            if [[ -z "$reason" ]]; then
                if ! tmux has-session -t "$session" 2>/dev/null; then
                    reason="missing_tmux_session"
                fi
            fi

            if [[ -z "$reason" ]]; then
                session_cooldown=$(jq -r ".sessions[\"$session\"].cooldownOverride // empty" "$SESSIONS_FILE")
                effective_cooldown="${session_cooldown:-$(jq -r '.config.cooldownNudges // 20' "$SESSIONS_FILE")}"
                if [[ "${nudge_count:-0}" -ge "${effective_cooldown:-20}" ]]; then
                    reason="cooldown_reached"
                fi
            fi

            if [[ -n "$reason" ]]; then
                found=1
                if [[ "$printed_header" -eq 0 ]]; then
                    printf '%-18s %-10s %-18s %s\n' "Session" "Mode" "Reason" "Intent"
                    printf '%-18s %-10s %-18s %s\n' "------------------" "----------" "------------------" "------------------------------"
                    printed_header=1
                fi
                intent=$(jq -r ".sessions[\"$session\"].intent // \"\"" "$SESSIONS_FILE")
                current_issue=$(jq -r ".sessions[\"$session\"].currentIssue // \"\"" "$SESSIONS_FILE")
                printf '%-18s %-10s %-18s %s\n' "$session" "${mode:-generic}" "$reason" "$intent${current_issue:+ ($current_issue)}"
            fi
        done < <(jq -r '.sessions | keys[]' "$SESSIONS_FILE")

        if [[ "$found" -eq 0 ]]; then
            echo "No sessions need attention."
        fi
        ;;

    *)
        usage
        exit 1
        ;;
esac
