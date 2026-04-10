#!/bin/bash
# nudge.sh — Intelligent tmux session monitor for AI coding agents.
#
# Reads session config from ~/.nudge/sessions.json
# For each active session:
#   1. Capture tmux pane output and save snapshot
#   2. Detect agent type (Codex, Claude Code, Gemini, generic shell)
#   3. Detect state: working | idle | done | ratelimited | blocked | asking | looping
#   4. Nudge only if idle for 2+ consecutive checks AND not done/blocked/looping
#   5. Compare snapshot hashes to detect stuck-in-a-loop agents
#   6. Log every decision for audit
#
# Requires: tmux, jq
# Compatible with macOS bash 3.2 and Linux (no mapfile, no bash 4+ features)
# Run via launchd (macOS) or cron/systemd (Linux) every 3 minutes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$HOME/.nudge"
SESSIONS_FILE="$STATE_DIR/sessions.json"
SNAPSHOTS_DIR="$STATE_DIR/snapshots"
LOG="$STATE_DIR/nudge.log"

mkdir -p "$STATE_DIR" "$SNAPSHOTS_DIR"

# --- Helpers ---

log() {
    local level="$1" session="$2" msg="$3"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $session: $msg" >> "$LOG"
}

# Cross-platform md5 hash (macOS: /sbin/md5, Linux: md5sum)
hash_text() {
    if command -v /sbin/md5 &>/dev/null; then
        /sbin/md5
    elif command -v md5sum &>/dev/null; then
        md5sum | cut -d' ' -f1
    elif command -v md5 &>/dev/null; then
        md5
    else
        # Fallback: use cksum (always available)
        cksum | cut -d' ' -f1
    fi
}

# Cross-platform stat for file size
file_size() {
    if stat -f%z "$1" 2>/dev/null; then
        return
    fi
    stat -c%s "$1" 2>/dev/null || echo 0
}

# Atomic JSON update with mkdir-based lock (POSIX-portable, no flock needed)
LOCKDIR="$STATE_DIR/.sessions.lock"
json_update() {
    local expr="$1"
    local max_wait=5
    local waited=0
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        sleep 0.2
        waited=$(( waited + 1 ))
        if (( waited >= max_wait * 5 )); then
            if [[ -d "$LOCKDIR" ]]; then
                local lock_age
                if stat -f%m "$LOCKDIR" &>/dev/null; then
                    lock_age=$(( $(date +%s) - $(stat -f%m "$LOCKDIR") ))
                else
                    lock_age=$(( $(date +%s) - $(stat -c%Y "$LOCKDIR" 2>/dev/null || echo 0) ))
                fi
                if (( lock_age > 10 )); then
                    rmdir "$LOCKDIR" 2>/dev/null || true
                    continue
                fi
            fi
            log "WARN" "system" "Could not acquire sessions.json lock after ${max_wait}s"
            return 1
        fi
    done
    if jq "$expr" "$SESSIONS_FILE" > "$SESSIONS_FILE.tmp" 2>/dev/null; then
        mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
    else
        rm -f "$SESSIONS_FILE.tmp"
        log "WARN" "system" "jq update failed: $expr"
    fi
    rmdir "$LOCKDIR" 2>/dev/null || true
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
                local lock_age
                if stat -f%m "$LOCKDIR" &>/dev/null; then
                    lock_age=$(( $(date +%s) - $(stat -f%m "$LOCKDIR") ))
                else
                    lock_age=$(( $(date +%s) - $(stat -c%Y "$LOCKDIR" 2>/dev/null || echo 0) ))
                fi
                if (( lock_age > 10 )); then
                    rmdir "$LOCKDIR" 2>/dev/null || true
                    continue
                fi
            fi
            log "WARN" "system" "Could not acquire sessions.json lock after ${max_wait}s"
            return 1
        fi
    done
    if jq "$@" "$jq_script" "$SESSIONS_FILE" > "$SESSIONS_FILE.tmp" 2>/dev/null; then
        mv "$SESSIONS_FILE.tmp" "$SESSIONS_FILE"
    else
        rm -f "$SESSIONS_FILE.tmp"
        log "WARN" "system" "jq update failed: $jq_script"
    fi
    rmdir "$LOCKDIR" 2>/dev/null || true
}

# Read file contents (avoids cat alias issues)
read_file() {
    /bin/cat "$1" 2>/dev/null || cat "$1" 2>/dev/null || true
}

update_runtime_state() {
    local session="$1"
    local runtime_state="$2"
    local current_issue="${3:-}"
    local status_reason="${4:-}"
    local exit_code="${5:-}"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    json_update_args \
        '
        .sessions[$session].runtimeState = $state
        | .sessions[$session].currentIssue = (if $issue == "" then null else $issue end)
        | .sessions[$session].lastStatusAt = $ts
        | .sessions[$session].lastStatusReason = (if $reason == "" then null else $reason end)
        | .sessions[$session].lastExitCode = (if $exitCode == "" then null else ($exitCode | tonumber?) end)
        ' \
        --arg session "$session" \
        --arg state "$runtime_state" \
        --arg issue "$current_issue" \
        --arg reason "$status_reason" \
        --arg ts "$ts" \
        --arg exitCode "$exit_code" >/dev/null || true
}

latest_nudge_status() {
    awk '/NUDGE_STATUS /{line=$0} END{print line}'
}

resolve_epic_helper() {
    if [[ -f "$SCRIPT_DIR/nudge-epic.sh" ]]; then
        printf '%s\n' "$SCRIPT_DIR/nudge-epic.sh"
        return 0
    fi
    if [[ -f "$HOME/scripts/nudge-epic.sh" ]]; then
        printf '%s\n' "$HOME/scripts/nudge-epic.sh"
        return 0
    fi
    return 1
}

maybe_restart_epic_session() {
    local session="$1"
    local runtime_state="$2"

    local auto_restart
    auto_restart=$(jq -r ".sessions[\"$session\"].autoRestart // true" "$SESSIONS_FILE")
    if [[ "$auto_restart" != "true" ]]; then
        return 1
    fi

    case "$runtime_state" in
        running|crashed)
            ;;
        *)
            return 1
            ;;
    esac

    local restart_count
    local max_restarts
    local cooldown_seconds
    local last_restart_epoch
    local now_epoch
    local now_iso
    restart_count=$(jq -r ".sessions[\"$session\"].restartCount // 0" "$SESSIONS_FILE")
    max_restarts=$(jq -r ".sessions[\"$session\"].maxAutoRestarts // 3" "$SESSIONS_FILE")
    cooldown_seconds=$(jq -r ".sessions[\"$session\"].restartCooldownSeconds // 300" "$SESSIONS_FILE")
    last_restart_epoch=$(jq -r ".sessions[\"$session\"].lastRestartEpoch // 0" "$SESSIONS_FILE")
    now_epoch=$(date +%s)
    now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if (( restart_count >= max_restarts )); then
        log "RESTART" "$session" "auto-restart limit reached ($restart_count/$max_restarts)"
        return 1
    fi

    if (( last_restart_epoch > 0 && now_epoch - last_restart_epoch < cooldown_seconds )); then
        log "RESTART" "$session" "backoff active (${now_epoch-last_restart_epoch}s < ${cooldown_seconds}s)"
        return 1
    fi

    local epic_helper
    if ! epic_helper=$(resolve_epic_helper); then
        log "RESTART" "$session" "could not find nudge-epic.sh helper"
        return 1
    fi

    if bash "$epic_helper" start "$session" >/dev/null 2>&1; then
        json_update_args \
            '
            .sessions[$session].restartCount = ((.sessions[$session].restartCount // 0) + 1)
            | .sessions[$session].lastRestartAt = $nowIso
            | .sessions[$session].lastRestartEpoch = ($nowEpoch | tonumber)
            | .sessions[$session].runtimeState = "running"
            | .sessions[$session].lastStatusAt = $nowIso
            | .sessions[$session].lastStatusReason = "auto-restarted after missing/crashed session"
            | .sessions[$session].lastExitCode = null
            ' \
            --arg session "$session" \
            --arg nowIso "$now_iso" \
            --arg nowEpoch "$now_epoch" >/dev/null || true
        log "RESTART" "$session" "auto-restarted bd_epic session"
        return 0
    fi

    log "RESTART" "$session" "auto-restart attempt failed"
    return 1
}

# Rotate log if over 500KB
log_size=$(file_size "$LOG" 2>/dev/null || echo 0)
if (( log_size > 512000 )); then
    mv "$LOG" "$LOG.prev"
    log "INFO" "system" "Log rotated (was ${log_size} bytes)"
fi

# Check dependencies
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq required but not found. Install: brew install jq (macOS) or apt install jq (Linux)" >&2
    exit 1
fi
if ! command -v tmux &>/dev/null; then
    echo "ERROR: tmux required but not found" >&2
    exit 1
fi

# Read config
if [[ ! -f "$SESSIONS_FILE" ]]; then
    exit 0  # No config yet
fi

NUDGE_MSG=$(jq -r '.config.nudgeMessage // "continue"' "$SESSIONS_FILE")
COOLDOWN=$(jq -r '.config.cooldownNudges // 20' "$SESSIONS_FILE")

COMPLETION_PATTERN=$(jq -r '.config.completionPhrases // [] | join("|")' "$SESSIONS_FILE" 2>/dev/null)
BLOCKED_PATTERN=$(jq -r '.config.blockedPhrases // [] | join("|")' "$SESSIONS_FILE" 2>/dev/null)

# --- Process each session ---

jq -r '.sessions | to_entries[] | select(.value.active == true and .value.paused != true and .value.completedAt == null and .value.depletedAt == null) | .key' "$SESSIONS_FILE" | while read -r session; do
    mode=$(jq -r ".sessions[\"$session\"].mode // \"generic\"" "$SESSIONS_FILE")
    runtime_state=$(jq -r ".sessions[\"$session\"].runtimeState // \"\"" "$SESSIONS_FILE")

    if ! tmux has-session -t "$session" 2>/dev/null; then
        if [[ "$mode" == "bd_epic" ]]; then
            if maybe_restart_epic_session "$session" "$runtime_state"; then
                continue
            fi
            update_runtime_state "$session" "crashed" "" "tmux session not found" ""
        fi
        log "SKIP" "$session" "tmux session not found"
        continue
    fi

    content=$(tmux capture-pane -t "$session" -p -S -40 2>/dev/null || true)

    if [[ -z "$content" ]]; then
        log "SKIP" "$session" "empty pane capture"
        continue
    fi

    echo "$content" > "$SNAPSHOTS_DIR/${session}.txt"

    idle_file="$STATE_DIR/${session}.idle"

    if [[ "$mode" == "bd_epic" ]]; then
        status_json=""
        status_file=$(jq -r ".sessions[\"$session\"].statusFile // empty" "$SESSIONS_FILE")
        if [[ -n "$status_file" && -f "$status_file" ]]; then
            status_json=$(read_file "$status_file")
        else
            status_line=$(echo "$content" | latest_nudge_status)
            if [[ -n "$status_line" ]]; then
                status_json="${status_line#*NUDGE_STATUS }"
            fi
        fi

        if [[ -n "$status_json" ]] && echo "$status_json" | jq -e . >/dev/null 2>&1; then
            epic_state=$(echo "$status_json" | jq -r '.state // "unknown"')
            epic_issue=$(echo "$status_json" | jq -r '.issue // ""')
            epic_reason=$(echo "$status_json" | jq -r '.reason // ""')
            epic_exit_code=$(echo "$status_json" | jq -r '.exitCode // ""')

            update_runtime_state "$session" "$epic_state" "$epic_issue" "$epic_reason" "$epic_exit_code"

            case "$epic_state" in
                running)
                    rm -f "$idle_file"
                    log "EPIC" "$session" "runner active${epic_issue:+ on $epic_issue}"
                    continue
                    ;;
                waiting_no_ready)
                    rm -f "$idle_file"
                    log "EPIC" "$session" "runner waiting for ready work${epic_reason:+ — $epic_reason}"
                    continue
                    ;;
                waiting_blocked)
                    rm -f "$idle_file"
                    log "EPIC" "$session" "runner blocked${epic_reason:+ — $epic_reason}"
                    continue
                    ;;
                waiting_human)
                    rm -f "$idle_file"
                    log "EPIC" "$session" "runner needs human review${epic_issue:+ on $epic_issue}${epic_reason:+ — $epic_reason}"
                    continue
                    ;;
                complete)
                    rm -f "$idle_file"
                    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
                    json_update "$(printf '.sessions[\"%s\"].completedAt = \"%s\"' "$session" "$now")" >/dev/null || true
                    log "DONE" "$session" "epic runner reported complete"
                    continue
                    ;;
                crashed)
                    rm -f "$idle_file"
                    log "CRASH" "$session" "epic runner reported crash${epic_exit_code:+ (exit $epic_exit_code)}${epic_reason:+ — $epic_reason}"
                    continue
                    ;;
            esac
        fi
    fi

    # --- Loop detection ---
    snap_hash=$(echo "$content" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^[[:space:]]*$' | tail -20 | hash_text)
    hash_file="$STATE_DIR/${session}.hash"
    hash_count_file="$STATE_DIR/${session}.hashcount"

    prev_hash=""
    if [[ -f "$hash_file" ]]; then
        prev_hash=$(read_file "$hash_file")
    fi

    if [[ "$snap_hash" == "$prev_hash" ]]; then
        prev_count=0
        if [[ -f "$hash_count_file" ]]; then
            prev_count=$(read_file "$hash_count_file")
        fi
        new_hash_count=$(( prev_count + 1 ))
        echo "$new_hash_count" > "$hash_count_file"
    else
        new_hash_count=0
        echo "$snap_hash" > "$hash_file"
        echo "0" > "$hash_count_file"
    fi

    LOOP_THRESHOLD=3
    is_looping=false
    if (( new_hash_count >= LOOP_THRESHOLD )); then
        is_looping=true
    fi

    # --- Agent type detection ---

    agent="unknown"
    if echo "$content" | grep -qE '(◦ Working|◦ Thinking|› |gpt-[0-9].*left ·)'; then
        agent="codex"
    elif echo "$content" | grep -qE '(Claude Code|claude-sonnet|claude-opus|Sonnet [0-9]|Opus [0-9]|✻ Cogitated|✻ Cooked|✢ Imagining|⏵⏵ .* on \(shift\+tab)'; then
        agent="claude"
    elif echo "$content" | grep -qE '(Gemini|gemini-[0-9])'; then
        agent="gemini"
    fi

    # --- State detection ---

    state="unknown"
    last_line=$(echo "$content" | grep -v '^[[:space:]]*$' | tail -1)

    case "$agent" in
        codex)
            if echo "$content" | grep -qE '(◦ Working|◦ Thinking) \('; then
                state="working"
            elif echo "$content" | grep -qE '^› '; then
                state="idle"
            fi
            if echo "$content" | grep -qiE 'rate limit|daily limit|weekly limit|usage limit|quota exceeded'; then
                state="ratelimited"
            fi
            ;;

        claude)
            if echo "$content" | tail -5 | grep -qE '(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|✻ |✢ |⠿|Thinking|Reading |Editing |Writing |Searching |Running )'; then
                state="working"
            elif echo "$content" | grep -q '^❯' ; then
                state="idle"
            elif echo "$content" | grep -qE 'Resume this session with:'; then
                state="idle"
            fi
            ;;

        gemini)
            if echo "$content" | tail -5 | grep -qE '(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|Generating|Thinking)'; then
                state="working"
            elif echo "$last_line" | grep -qE '^> $|^>$|^❯ $'; then
                state="idle"
            fi
            ;;

        *)
            if echo "$last_line" | grep -qE '(\$|%|>|❯)\s*$'; then
                state="idle"
            fi
            ;;
    esac

    # --- Secondary checks ---

    if [[ "$state" == "idle" ]]; then
        pre_prompt=$(echo "$content" | grep -v '^[[:space:]]*$' | tail -8 | head -5)
        if echo "$pre_prompt" | grep -qiE '\[y/n\]|\[Y/n\]|would you like me to|do you want me to|shall I |please confirm|approve this|select.*option|which .* would you|choose .* to '; then
            state="asking"
        fi

        if [[ "$state" == "idle" ]] && [[ -n "$COMPLETION_PATTERN" ]]; then
            if echo "$content" | grep -qiE "$COMPLETION_PATTERN"; then
                state="done"
            fi
        fi

        if [[ "$state" == "idle" ]] && [[ -n "$BLOCKED_PATTERN" ]]; then
            if echo "$content" | grep -qiE "$BLOCKED_PATTERN"; then
                state="blocked"
            fi
        fi
    fi

    if $is_looping && [[ "$state" == "idle" ]]; then
        state="looping"
    fi

    # --- Act on state ---

    case "$state" in
        working)
            rm -f "$idle_file"
            ;;

        idle)
            # Per-session cooldown override takes precedence over global
            session_cooldown=$(jq -r ".sessions[\"$session\"].cooldownOverride // empty" "$SESSIONS_FILE")
            effective_cooldown="${session_cooldown:-$COOLDOWN}"
            current_count=$(jq -r ".sessions[\"$session\"].nudgeCount // 0" "$SESSIONS_FILE")
            if (( current_count >= effective_cooldown )); then
                log "COOL" "$session" "nudge cooldown reached ($current_count/$effective_cooldown) — skipping"
                continue
            fi

            if [[ -f "$idle_file" ]]; then
                tmux send-keys -t "$session" -l "$NUDGE_MSG"
                sleep 0.3
                tmux send-keys -t "$session" Enter
                rm -f "$idle_file"

                now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
                json_update "$(printf '.sessions["%s"].nudgeCount = ((.sessions["%s"].nudgeCount // 0) + 1) | .sessions["%s"].lastNudge = "%s" | .sessions["%s"].agent = "%s"' "$session" "$session" "$session" "$now" "$session" "$agent")"

                new_count=$(( current_count + 1 ))
                log "NUDGE" "$session" "sent '$NUDGE_MSG' (nudge #$new_count, agent=$agent)"
            else
                touch "$idle_file"
                log "IDLE" "$session" "marked idle — will nudge on next check if still idle (agent=$agent)"
            fi
            ;;

        looping)
            rm -f "$idle_file"
            log "LOOP" "$session" "identical output for $new_hash_count cycles — not nudging (agent=$agent)"
            ;;

        done)
            rm -f "$idle_file"
            now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            json_update "$(printf '.sessions["%s"].completedAt = "%s"' "$session" "$now")"
            log "DONE" "$session" "completion signal detected — stopped monitoring"
            ;;

        ratelimited)
            rm -f "$idle_file"
            now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            json_update "$(printf '.sessions["%s"].depletedAt = "%s"' "$session" "$now")"
            log "LIMIT" "$session" "rate/usage limit detected — stopped monitoring"
            ;;

        blocked)
            rm -f "$idle_file"
            log "BLOCK" "$session" "appears blocked — not nudging (agent=$agent)"
            ;;

        asking)
            rm -f "$idle_file"
            log "ASK" "$session" "agent asking a question — not nudging (agent=$agent)"
            ;;

        *)
            rm -f "$idle_file"
            ;;
    esac
done
