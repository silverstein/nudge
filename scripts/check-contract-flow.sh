#!/bin/bash
# Smoke-check the nudge contract/bootstrap/attention flow.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

bash -n scripts/nudge.sh
bash -n scripts/nudge-epic.sh
bash -n scripts/nudge-attention.sh
bash -n scripts/nudge-status.sh
bash -n install.sh

tmp_root=$(mktemp -d)
trap 'tmux kill-session -t fake-smoke 2>/dev/null || true; rm -rf "$tmp_root"' EXIT

repo="$tmp_root/repo"
home="$tmp_root/home"
mkdir -p "$repo/scripts" "$home/.nudge/runtime" "$home/.nudge/snapshots"

cat > "$repo/nudge.json" <<'JSON'
{
  "version": 1,
  "session_modes": {
    "bd_epic": {
      "runner_interface": "codex_epic_v1",
      "runner": "bash scripts/fake-runner.sh",
      "default_agent_bin": "codex",
      "default_agent_args": [],
      "default_taskmaster": false,
      "status_file_env": "NUDGE_STATUS_FILE",
      "states": ["running", "waiting_human", "complete", "crashed"],
      "required_commands": ["bash"],
      "required_files": ["scripts/fake-runner.sh"]
    }
  }
}
JSON

cat > "$repo/scripts/fake-runner.sh" <<'SH'
#!/bin/bash
set -euo pipefail
epic_id="$1"
printf '%s' "{\"state\":\"waiting_human\",\"epic\":\"${epic_id}\",\"reason\":\"fake runner pause\"}" > "$NUDGE_STATUS_FILE"
printf 'NUDGE_STATUS {"state":"waiting_human","epic":"%s","reason":"fake runner pause"}\n' "$epic_id"
sleep 5
SH
chmod +x "$repo/scripts/fake-runner.sh"

HOME="$home" bash scripts/nudge-epic.sh doctor "$repo" >/dev/null
HOME="$home" bash scripts/nudge-epic.sh bootstrap fake-smoke "$repo" demo-epic --start >/dev/null
sleep 1
HOME="$home" bash scripts/nudge.sh >/dev/null

runtime_state=$(HOME="$home" jq -r '.sessions["fake-smoke"].runtimeState' "$home/.nudge/sessions.json")
last_reason=$(HOME="$home" jq -r '.sessions["fake-smoke"].lastStatusReason' "$home/.nudge/sessions.json")

if [[ "$runtime_state" != "waiting_human" ]]; then
    echo "Expected runtimeState=waiting_human, got $runtime_state" >&2
    exit 1
fi

if [[ "$last_reason" != "fake runner pause" ]]; then
    echo "Expected lastStatusReason=fake runner pause, got $last_reason" >&2
    exit 1
fi

attention_output=$(HOME="$home" bash scripts/nudge-epic.sh attention)
echo "$attention_output" | grep -q "fake-smoke"
echo "$attention_output" | grep -q "waiting_human"

status_output=$(HOME="$home" bash scripts/nudge-status.sh)
echo "$status_output" | grep -q "Attention"
echo "$status_output" | grep -q "fake-smoke"

tmux kill-session -t fake-smoke
HOME="$home" jq '.sessions["fake-smoke"].runtimeState = "crashed"' "$home/.nudge/sessions.json" > "$home/.nudge/sessions.json.tmp"
mv "$home/.nudge/sessions.json.tmp" "$home/.nudge/sessions.json"
HOME="$home" bash scripts/nudge.sh >/dev/null
sleep 1
tmux has-session -t fake-smoke
restart_count=$(HOME="$home" jq -r '.sessions["fake-smoke"].restartCount' "$home/.nudge/sessions.json")
if [[ "$restart_count" -lt 1 ]]; then
    echo "Expected restartCount >= 1, got $restart_count" >&2
    exit 1
fi

tmux kill-session -t fake-smoke 2>/dev/null || true

echo "nudge contract flow smoke check passed"
