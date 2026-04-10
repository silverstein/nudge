#!/bin/bash
# Thin wrapper so humans/agents can run one command without remembering subcommands.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/nudge-epic.sh" ]]; then
    exec "$SCRIPT_DIR/nudge-epic.sh" attention
fi
exec "$HOME/scripts/nudge-epic.sh" attention
