#!/bin/bash
# Human/agent-friendly status output with attention surfaced first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.nudge"
SESSIONS_FILE="$STATE_DIR/sessions.json"

if [[ ! -f "$SESSIONS_FILE" ]]; then
    echo "No nudge config yet."
    exit 0
fi

EPIC_HELPER="$HOME/scripts/nudge-epic.sh"
if [[ -f "$SCRIPT_DIR/nudge-epic.sh" ]]; then
    EPIC_HELPER="$SCRIPT_DIR/nudge-epic.sh"
fi

attention_output=$(bash "$EPIC_HELPER" attention 2>/dev/null || true)
if [[ -n "$attention_output" && "$attention_output" != "No sessions need attention." ]]; then
    echo "Attention"
    echo "---------"
    echo "$attention_output"
    echo ""
fi

echo "Sessions"
echo "--------"
printf '%-18s %-10s %-18s %-8s %s\n' "Session" "Mode" "State" "tmux" "Intent"
printf '%-18s %-10s %-18s %-8s %s\n' "------------------" "----------" "------------------" "--------" "------------------------------"

while IFS= read -r session; do
    mode=$(jq -r ".sessions[\"$session\"].mode // \"generic\"" "$SESSIONS_FILE")
    paused=$(jq -r ".sessions[\"$session\"].paused // false" "$SESSIONS_FILE")
    completed=$(jq -r ".sessions[\"$session\"].completedAt // \"null\"" "$SESSIONS_FILE")
    depleted=$(jq -r ".sessions[\"$session\"].depletedAt // \"null\"" "$SESSIONS_FILE")
    runtime_state=$(jq -r ".sessions[\"$session\"].runtimeState // \"\"" "$SESSIONS_FILE")
    intent=$(jq -r ".sessions[\"$session\"].intent // \"\"" "$SESSIONS_FILE")

    state="active"
    if [[ "$paused" == "true" ]]; then
        state="paused"
    elif [[ "$completed" != "null" ]]; then
        state="complete"
    elif [[ "$depleted" != "null" ]]; then
        state="depleted"
    elif [[ -n "$runtime_state" ]]; then
        state="$runtime_state"
    fi

    tmux_status="missing"
    if tmux has-session -t "$session" 2>/dev/null; then
        tmux_status="present"
    fi

    printf '%-18s %-10s %-18s %-8s %s\n' "$session" "$mode" "$state" "$tmux_status" "$intent"
done < <(jq -r '.sessions | keys[]' "$SESSIONS_FILE")
